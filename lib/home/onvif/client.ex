defmodule Home.Onvif.Client do
  @moduledoc """
  The ONVIF calls `Home.Onvif.add_camera/2` makes, through `ex_onvif` (SOAP over HTTP
  with WS-Security UsernameToken digest auth, falling back to HTTP digest and basic):

    1. `GetSystemDateAndTime` (unauthenticated) for the camera's clock offset, which
       the UsernameToken `Created` stamp must match,
    2. `GetDeviceInformation` - also how the auth scheme and credentials are checked,
    3. `GetServices` for the media service address,
    4. `GetProfiles`, then `GetStreamUri` (RTP-Unicast over RTSP) for the chosen profile.

  `ExOnvif.Device.new/3` does 1-3 too, but assumes the default device service path and
  reports bad credentials as a string; this keeps the URL's path and returns
  `{:error, :unauthorized}`.
  """

  alias ExOnvif.{Devices, Media}

  @media_ns "http://www.onvif.org/ver10/media/wsdl"

  @doc """
  Talk to the camera at `url` (its device service, e.g. `http://10.0.0.5/onvif/device_service`;
  a bare `http://host[:port]` means the default path). Returns
  `{:ok, %{device: info, profile: profile, stream_uri: uri, profiles: [summary]}}`.

  `profile`: `nil` (the first H.264 profile), a profile token or name, or an index.
  """
  def describe(url, username, password, profile \\ nil) do
    with {:ok, device} <- device(url, username, password),
         {:ok, profiles} <- call(fn -> Media.get_profiles(device) end),
         {:ok, chosen} <- pick(profiles, profile),
         {:ok, uri} <-
           call(fn ->
             Media.get_stream_uri(device, chosen.reference_token, "RTP-Unicast", "RTSP")
           end),
         {:ok, uri} <- check_uri(uri) do
      {:ok,
       %{
         device:
           Map.take(device, [
             :manufacturer,
             :model,
             :firmware_version,
             :serial_number,
             :hardware_id
           ]),
         profile: summary(chosen),
         profiles: Enum.map(profiles, &summary/1),
         stream_uri: uri
       }}
    end
  end

  defp device(url, username, password) do
    uri = URI.parse(url)
    path = if uri.path in [nil, "", "/"], do: "/onvif/device_service", else: uri.path

    base = %ExOnvif.Device{
      address: "#{uri.scheme}://#{uri.host}:#{uri.port}",
      port: uri.port,
      username: username,
      password: password,
      device_service_path: path
    }

    with {:ok, base} <- clock(base),
         {:ok, device} <- authenticate(base, [:xml_auth, :digest_auth, :basic_auth], nil) do
      services =
        case call(fn -> Devices.get_services(device) end) do
          {:ok, services} -> services
          _ -> []
        end

      media =
        case Enum.find(services, &(&1.namespace == @media_ns)) do
          %{xaddr: xaddr} -> URI.parse(xaddr).path
          # No GetServices: many cameras serve every service at the device address.
          nil -> path
        end

      {:ok, %{device | media_ver10_service_path: media}}
    end
  end

  defp clock(device) do
    case call(fn -> Devices.get_system_date_and_time(device) end) do
      {:ok, time} ->
        {:ok, %{device | time_diff_from_system_secs: time.current_diff || 0}}

      # Unreachable: no HTTP response at all.
      {:error, %{status: nil, response: reason}} ->
        {:error, {:unreachable, reason}}

      # Reachable but no usable clock: assume it is in sync.
      {:error, _} ->
        {:ok, device}
    end
  end

  defp authenticate(_device, [], last), do: {:error, last || :unauthorized}

  defp authenticate(device, [auth | rest], last) do
    device = %{device | auth_type: auth}

    case call(fn -> Devices.get_device_information(device) end) do
      {:ok, info} ->
        {:ok,
         Map.merge(
           device,
           Map.take(info, [:manufacturer, :model, :firmware_version, :serial_number, :hardware_id])
         )}

      {:error, reason} ->
        authenticate(
          device,
          rest,
          if(auth_error?(reason), do: :unauthorized, else: last || reason)
        )
    end
  end

  defp auth_error?(%ExOnvif.Fault{} = fault),
    do: inspect(fault) =~ ~r/NotAuthorized|Unauthorized|FailedAuthentication|Sender/i

  defp auth_error?(%{status: status}) when status in [400, 401, 403], do: true
  defp auth_error?(_), do: false

  defp pick([], _), do: {:error, :no_profiles}

  defp pick(profiles, nil) do
    case Enum.find(profiles, &(encoding(&1) == :h264)) do
      nil -> {:error, {:unsupported_encoding, encoding(hd(profiles))}}
      profile -> {:ok, profile}
    end
  end

  defp pick(profiles, index) when is_integer(index) do
    case Enum.at(profiles, index) do
      nil -> {:error, {:no_profile, index}}
      profile -> h264(profile)
    end
  end

  defp pick(profiles, name) when is_binary(name) do
    case Enum.find(profiles, &(&1.reference_token == name or &1.name == name)) do
      nil -> {:error, {:no_profile, name}}
      profile -> h264(profile)
    end
  end

  defp h264(profile) do
    case encoding(profile) do
      :h264 -> {:ok, profile}
      other -> {:error, {:unsupported_encoding, other}}
    end
  end

  defp encoding(%{video_encoder_configuration: %{encoding: encoding}}), do: encoding
  defp encoding(_profile), do: nil

  defp summary(profile) do
    vec = profile.video_encoder_configuration || %{}
    resolution = Map.get(vec, :resolution) || %{}
    rate = Map.get(vec, :rate_control) || %{}

    %{
      token: profile.reference_token,
      name: profile.name,
      encoding: Map.get(vec, :encoding),
      w: Map.get(resolution, :width),
      h: Map.get(resolution, :height),
      fps: Map.get(rate, :frame_rate_limit),
      bitrate: Map.get(rate, :bitrate_limit)
    }
  end

  defp check_uri("rtsp" <> _ = uri), do: {:ok, uri}
  defp check_uri(other), do: {:error, {:bad_stream_uri, other}}

  # ex_onvif can raise (or exit, from the XML parser) on bodies it doesn't expect.
  defp call(fun) do
    fun.()
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end

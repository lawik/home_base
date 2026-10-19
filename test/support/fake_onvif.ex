defmodule Home.Test.FakeOnvif do
  @moduledoc false
  # The ONVIF side of a fake IP camera, on the test node:
  #
  #   * device and media SOAP services over Bandit at http://127.0.0.1:PORT/onvif/...:
  #     GetSystemDateAndTime (unauthenticated), GetDeviceInformation, GetServices,
  #     GetProfiles, GetStreamUri. Every call but the first needs a WS-Security
  #     UsernameToken whose PasswordDigest (Base64(SHA1(nonce <> created <> password)))
  #     checks out against the configured credentials; otherwise a SOAP
  #     `ter:NotAuthorized` fault, HTTP 400, as cameras do.
  #   * a WS-Discovery responder: a UDP socket answering `Probe`s for
  #     NetworkVideoTransmitter with a `ProbeMatch` carrying the device service XAddr.
  #
  #     {:ok, onvif} = FakeOnvif.start_link(rtsp: rtsp_url, username: "admin", password: "pw")
  #     FakeOnvif.info(onvif) #=> %{http_port: p, discovery_port: q, url: "http://..."}

  use GenServer

  @soap "http://www.w3.org/2003/05/soap-envelope"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def info(onvif), do: GenServer.call(onvif, :info)

  @doc "Requests seen, newest first: `{action, authorized?}`."
  def requests(onvif), do: GenServer.call(onvif, :requests)

  ## Server

  @impl true
  def init(opts) do
    config = %{
      username: Keyword.get(opts, :username, "admin"),
      password: Keyword.get(opts, :password, "admin"),
      rtsp: Keyword.fetch!(opts, :rtsp),
      size: Keyword.get(opts, :size, {320, 240}),
      fps: Keyword.get(opts, :fps, 30),
      name: Keyword.get(opts, :name, "FakeCam"),
      uuid: "urn:uuid:" <> Ecto.UUID.generate(),
      server: self()
    }

    {:ok, bandit} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, config},
        ip: {127, 0, 0, 1},
        port: Keyword.get(opts, :http_port, 0),
        startup_log: false
      )

    {:ok, {_ip, http_port}} = ThousandIsland.listener_info(bandit)
    url = "http://127.0.0.1:#{http_port}/onvif/device_service"

    {:ok, socket} =
      :gen_udp.open(Keyword.get(opts, :discovery_port, 0), [
        :binary,
        active: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, discovery_port} = :inet.port(socket)

    {:ok,
     %{
       bandit: bandit,
       socket: socket,
       config: config,
       url: url,
       http_port: http_port,
       discovery_port: discovery_port,
       requests: []
     }}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      url: state.url,
      http_port: state.http_port,
      discovery_port: state.discovery_port,
      endpoint: state.config.uuid
    }

    {:reply, info, state}
  end

  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  @impl true
  def handle_cast({:request, action, ok?}, state),
    do: {:noreply, %{state | requests: [{action, ok?} | state.requests]}}

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    case probe_id(data) do
      nil -> :ok
      id -> :gen_udp.send(socket, ip, port, probe_match(id, state))
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp probe_id(data) do
    if data =~ "Probe" and data =~ "NetworkVideoTransmitter" do
      case Regex.run(~r{<[A-Za-z0-9]*:?MessageID[^>]*>([^<]+)<}, data) do
        [_, id] -> String.trim(id)
        nil -> nil
      end
    end
  end

  defp probe_match(relates_to, state) do
    c = state.config

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <s:Envelope xmlns:s="#{@soap}" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
    xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
    xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
    <s:Header>\
    <a:MessageID>urn:uuid:#{Ecto.UUID.generate()}</a:MessageID>\
    <a:RelatesTo>#{relates_to}</a:RelatesTo>\
    <a:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:To>\
    <a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</a:Action>\
    </s:Header>\
    <s:Body><d:ProbeMatches><d:ProbeMatch>\
    <a:EndpointReference><a:Address>#{c.uuid}</a:Address></a:EndpointReference>\
    <d:Types>dn:NetworkVideoTransmitter</d:Types>\
    <d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/#{URI.encode(c.name)} \
    onvif://www.onvif.org/hardware/FC-1</d:Scopes>\
    <d:XAddrs>#{state.url}</d:XAddrs>\
    <d:MetadataVersion>1</d:MetadataVersion>\
    </d:ProbeMatch></d:ProbeMatches></s:Body>\
    </s:Envelope>\
    """
  end
end

defmodule Home.Test.FakeOnvif.Plug do
  @moduledoc false
  import Plug.Conn

  @soap "http://www.w3.org/2003/05/soap-envelope"
  @tds "http://www.onvif.org/ver10/device/wsdl"
  @trt "http://www.onvif.org/ver10/media/wsdl"
  @tt "http://www.onvif.org/ver10/schema"

  def init(config), do: config

  def call(%{method: "POST", request_path: "/onvif/" <> _} = conn, config) do
    {:ok, body, conn} = read_body(conn)
    action = action(body)
    authorized? = action == "GetSystemDateAndTime" or authorized?(body, config)
    GenServer.cast(config.server, {:request, action, authorized?})

    {status, xml} =
      if authorized?,
        do: respond(action, body, conn, config),
        else: {400, not_authorized()}

    conn
    |> put_resp_content_type("application/soap+xml")
    |> send_resp(status, envelope(xml))
  end

  def call(conn, _config), do: send_resp(conn, 404, "")

  defp action(body) do
    case Regex.run(~r{<s:Body>\s*<[A-Za-z0-9]+:([A-Za-z]+)}, body) do
      [_, action] -> action
      nil -> nil
    end
  end

  # WS-Security UsernameToken, PasswordDigest.
  defp authorized?(body, config) do
    with [_, user] <- Regex.run(~r{<wsse:Username>([^<]*)</wsse:Username>}, body),
         [_, digest] <- Regex.run(~r{<wsse:Password[^>]*>([^<]*)</wsse:Password>}, body),
         [_, nonce] <- Regex.run(~r{<wsse:Nonce[^>]*>([^<]*)</wsse:Nonce>}, body),
         [_, created] <- Regex.run(~r{<wsu:Created>([^<]*)</wsu:Created>}, body),
         {:ok, nonce} <- Base.decode64(nonce) do
      expected = :crypto.hash(:sha, nonce <> created <> config.password) |> Base.encode64()
      user == config.username and digest == expected
    else
      _ -> false
    end
  end

  defp respond("GetSystemDateAndTime", _body, _conn, _config) do
    now = DateTime.utc_now()

    {200,
     """
     <tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime>\
     <tt:DateTimeType>NTP</tt:DateTimeType><tt:DaylightSavings>false</tt:DaylightSavings>\
     <tt:TimeZone><tt:TZ>UTC</tt:TZ></tt:TimeZone>\
     <tt:UTCDateTime><tt:Time><tt:Hour>#{now.hour}</tt:Hour><tt:Minute>#{now.minute}</tt:Minute>\
     <tt:Second>#{now.second}</tt:Second></tt:Time><tt:Date><tt:Year>#{now.year}</tt:Year>\
     <tt:Month>#{now.month}</tt:Month><tt:Day>#{now.day}</tt:Day></tt:Date></tt:UTCDateTime>\
     </tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>\
     """}
  end

  defp respond("GetDeviceInformation", _body, _conn, _config) do
    {200,
     """
     <tds:GetDeviceInformationResponse><tds:Manufacturer>Home Test</tds:Manufacturer>\
     <tds:Model>FakeCam 1</tds:Model><tds:FirmwareVersion>1.0.0</tds:FirmwareVersion>\
     <tds:SerialNumber>FC0001</tds:SerialNumber><tds:HardwareId>FC-1</tds:HardwareId>\
     </tds:GetDeviceInformationResponse>\
     """}
  end

  defp respond("GetServices", _body, conn, _config) do
    base = "http://127.0.0.1:#{conn.port}/onvif"

    {200,
     """
     <tds:GetServicesResponse>\
     <tds:Service><tds:Namespace>#{@tds}</tds:Namespace><tds:XAddr>#{base}/device_service</tds:XAddr>\
     <tds:Version><tt:Major>2</tt:Major><tt:Minor>60</tt:Minor></tds:Version></tds:Service>\
     <tds:Service><tds:Namespace>#{@trt}</tds:Namespace><tds:XAddr>#{base}/media_service</tds:XAddr>\
     <tds:Version><tt:Major>2</tt:Major><tt:Minor>60</tt:Minor></tds:Version></tds:Service>\
     </tds:GetServicesResponse>\
     """}
  end

  defp respond("GetProfiles", _body, _conn, config) do
    {w, h} = config.size

    {200,
     """
     <trt:GetProfilesResponse>\
     #{profile("mjpeg_sub", "Sub", "JPEG", {div(w, 2), div(h, 2)}, 5)}\
     #{profile("main", "Main", "H264", {w, h}, config.fps)}\
     </trt:GetProfilesResponse>\
     """}
  end

  defp respond("GetStreamUri", body, _conn, config) do
    if body =~ ~r{ProfileToken>\s*main\s*<} do
      {200,
       """
       <trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>#{config.rtsp}</tt:Uri>\
       <tt:InvalidAfterConnect>false</tt:InvalidAfterConnect>\
       <tt:InvalidAfterReboot>false</tt:InvalidAfterReboot><tt:Timeout>PT0S</tt:Timeout>\
       </trt:MediaUri></trt:GetStreamUriResponse>\
       """}
    else
      {400, fault("ter:InvalidArgVal", "ter:NoProfile", "no such profile")}
    end
  end

  defp respond(_action, _body, _conn, _config),
    do: {400, fault("ter:ActionNotSupported", "ter:NotSupported", "not supported")}

  defp profile(token, name, encoding, {w, h}, fps) do
    """
    <trt:Profiles token="#{token}" fixed="true"><tt:Name>#{name}</tt:Name>\
    <tt:VideoSourceConfiguration token="vsc"><tt:Name>vsc</tt:Name><tt:UseCount>2</tt:UseCount>\
    <tt:SourceToken>vs</tt:SourceToken><tt:Bounds x="0" y="0" width="#{w}" height="#{h}"/>\
    </tt:VideoSourceConfiguration>\
    <tt:VideoEncoderConfiguration token="vec_#{token}"><tt:Name>#{name}</tt:Name>\
    <tt:UseCount>1</tt:UseCount><tt:Encoding>#{encoding}</tt:Encoding>\
    <tt:Resolution><tt:Width>#{w}</tt:Width><tt:Height>#{h}</tt:Height></tt:Resolution>\
    <tt:Quality>5</tt:Quality><tt:RateControl><tt:FrameRateLimit>#{fps}</tt:FrameRateLimit>\
    <tt:EncodingInterval>1</tt:EncodingInterval><tt:BitrateLimit>2048</tt:BitrateLimit>\
    </tt:RateControl><tt:SessionTimeout>PT60S</tt:SessionTimeout>\
    </tt:VideoEncoderConfiguration></trt:Profiles>\
    """
  end

  defp not_authorized,
    do: fault("ter:NotAuthorized", nil, "The action requested requires authorization")

  defp fault(subcode, subsubcode, reason) do
    inner =
      if subsubcode,
        do: "<s:Subcode><s:Value>#{subsubcode}</s:Value></s:Subcode>",
        else: ""

    """
    <s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>#{subcode}</s:Value>\
    #{inner}</s:Subcode></s:Code><s:Reason><s:Text xml:lang="en">#{reason}</s:Text></s:Reason>\
    </s:Fault>\
    """
  end

  defp envelope(body) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <s:Envelope xmlns:s="#{@soap}" xmlns:tds="#{@tds}" xmlns:trt="#{@trt}" xmlns:tt="#{@tt}" \
    xmlns:ter="http://www.onvif.org/ver10/error"><s:Body>#{body}</s:Body></s:Envelope>\
    """
  end
end

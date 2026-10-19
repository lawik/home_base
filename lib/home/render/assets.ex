defmodule Home.Render.Assets do
  @moduledoc """
  Image sources of a forwarded emerge tree (§6.1 asset manifest).

  A display node resolves an app's images as logical paths under a per-session
  directory (`Home.Render.Compositor`). Logical sources (`"images/x.png"`, `~m`, atoms)
  are files in the app's `priv/` and go over as they are. The two other kinds of source
  only mean something on the app's node, so `Home.Render.Remote` rewrites them, before
  emerge diffs the tree, into logical paths named by content hash:

    * `{:path, "/abs/file.jpg"}` (a runtime path) becomes `"_home/<sha256>.jpg"`;
    * `{:id, "img_<sha256>"}` (emerge's canonical id for an image's bytes) becomes
      `"_home/<sha256>"` (`.svg` for SVG), if this node has those bytes: put them here
      with `put_image/1`, which returns the id.

  The bytes then go to the display by hash like any other asset, and the same image on
  several displays, or under several paths, is sent once per display node. The app's
  own tree is untouched; only what emerge encodes for the display is rewritten.
  """

  @prefix "_home/"

  @doc """
  Keep `data` (an encoded image) on this node for forwarded trees and return emerge's
  id for it, `{:id, "img_<sha256>"}`, to use as an image source.
  """
  @spec put_image(binary()) :: {:id, String.t()}
  def put_image(data) when is_binary(data) do
    hash = Home.Render.Compositor.hash(data)
    path = store_path(hash)

    unless File.regular?(path) do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp#{System.unique_integer([:positive])}"
      File.write!(tmp, data)
      File.rename!(tmp, path)
    end

    {:id, "img_" <> hash}
  end

  @doc "This node's content-addressed asset store (shared with the compositor's cache)."
  def store_path(hash), do: Path.join([Home.data_dir(), "render", "assets", hash])

  @doc """
  Rewrite runtime-path and id sources in `tree` to hashed logical paths. Returns the
  tree and `%{logical => {file, hash}}` for the rewritten ones. Hashes of runtime paths
  are cached in the calling process by path, size, mtime and inode (replace a file by
  renaming a new one over it, or change its size, for a same-second change to show).
  """
  @spec rewrite(Emerge.Engine.Element.t() | nil) ::
          {term(), %{String.t() => {Path.t(), String.t()}}}
  def rewrite(nil), do: {nil, %{}}

  def rewrite(tree) do
    Process.put({__MODULE__, :files}, %{})
    tree = map_sources(tree, &rewrite_source/1)
    {tree, Process.delete({__MODULE__, :files})}
  end

  @doc "The logical image paths `tree` uses (the ones resolved against a priv dir or `_home/`)."
  def logical_paths(nil), do: []

  def logical_paths(tree) do
    Process.put({__MODULE__, :logical}, [])

    map_sources(tree, fn src ->
      if path = logical(src),
        do: Process.put({__MODULE__, :logical}, [path | Process.get({__MODULE__, :logical})])

      src
    end)

    {__MODULE__, :logical} |> Process.delete() |> Enum.uniq()
  end

  @doc "A logical source as a relative path, or nil for runtime paths and ids."
  def logical(%Emerge.Assets.Ref{path: path}), do: path
  def logical(path) when is_binary(path), do: String.trim_leading(path, "/")
  def logical(path) when is_atom(path) and not is_nil(path), do: Atom.to_string(path)
  def logical(_), do: nil

  @doc "Whether `logical` is one of ours (`_home/<sha256>...`); returns the hash."
  def hashed(@prefix <> rest), do: rest |> Path.rootname() |> valid_hash()
  def hashed(_), do: nil

  ## Internals

  # Image sources sit in `image_src` and `background: {:image, src, fit}`, also inside
  # nested attribute maps (interaction states such as `mouse_over`).
  defp map_sources(%Emerge.Engine.Element{} = el, fun) do
    %{
      el
      | attrs: map_attrs(el.attrs, fun),
        children: Enum.map(el.children, &map_sources(&1, fun)),
        nearby: Enum.map(el.nearby, fn {slot, child} -> {slot, map_sources(child, fun)} end)
    }
  end

  defp map_sources(other, _fun), do: other

  defp map_attrs(attrs, fun) when is_map(attrs) do
    Map.new(attrs, fn
      {:image_src, src} -> {:image_src, fun.(src)}
      {:background, {:image, src, fit}} -> {:background, {:image, fun.(src), fit}}
      {key, %{} = nested} when not is_struct(nested) -> {key, map_attrs(nested, fun)}
      other -> other
    end)
  end

  defp map_attrs(attrs, _fun), do: attrs

  defp rewrite_source({:path, path} = src) when is_binary(path) do
    case path_hash(path) do
      nil -> src
      hash -> record(@prefix <> hash <> String.downcase(Path.extname(path)), path, hash)
    end
  end

  defp rewrite_source({:id, "img_" <> hash} = src) do
    with hash when is_binary(hash) <- valid_hash(hash),
         file = store_path(hash),
         ext when is_binary(ext) <- stored_ext(file) do
      record(@prefix <> hash <> ext, file, hash)
    else
      _ -> src
    end
  end

  defp rewrite_source(src), do: src

  defp record(logical, file, hash) do
    Process.put(
      {__MODULE__, :files},
      Map.put(Process.get({__MODULE__, :files}), logical, {file, hash})
    )

    logical
  end

  defp path_hash(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime, inode: inode}} ->
        key = {__MODULE__, :hash, path}
        stamp = {size, mtime, inode}

        case Process.get(key) do
          {^stamp, hash} ->
            hash

          _ ->
            case File.read(path) do
              {:ok, data} ->
                hash = Home.Render.Compositor.hash(data)
                Process.put(key, {stamp, hash})
                hash

              _ ->
                nil
            end
        end

      _ ->
        nil
    end
  end

  # Emerge picks SVG by extension; ids carry none, so look at the bytes once.
  defp stored_ext(file) do
    key = {__MODULE__, :ext, file}

    case Process.get(key) do
      nil ->
        ext =
          case File.open(file, [:read, :binary], &IO.binread(&1, 512)) do
            {:ok, head} when is_binary(head) -> if svg?(head), do: ".svg", else: ""
            _ -> nil
          end

        if ext, do: Process.put(key, ext)
        ext

      ext ->
        ext
    end
  end

  defp svg?(head) do
    head = String.trim_leading(head)
    String.starts_with?(head, "<svg") or (String.starts_with?(head, "<?xml") and head =~ "<svg")
  end

  defp valid_hash(hash) do
    if byte_size(hash) == 64 and hash =~ ~r/\A[0-9a-f]+\z/, do: hash
  end
end

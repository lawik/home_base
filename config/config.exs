import Config

# Backends for a source build of emerge's NIF (EMERGE_SKIA_BUILD=true), e.g.
# HOME_EMERGE_BACKENDS='[wayland: [:opengl], drm: [:raster], headless: [:opengl]]' for
# DRM/KMS output on a machine without GPU drivers. Unset: emerge's default for the host.
if backends = System.get_env("HOME_EMERGE_BACKENDS") do
  {backends, _} = Code.eval_string(backends)
  config :emerge, compiled_backends: backends
end

# Helpers

`llama-server` goes here, built from pinned llama.cpp source by `scripts/build-llama-server.sh`
(static, Metal with the shader library embedded, OS libraries only). The Xcode build copies it
into `Scribeski.app/Contents/Helpers/` and signs it with hardened runtime. The binary itself is
a build product and isn't committed.

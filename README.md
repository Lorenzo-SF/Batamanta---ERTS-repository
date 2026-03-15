<p align="center">
  <img src="/Assets/batamantaman-sit.png" alt="Batamanta Elixir Man">
</p>

Welcome to the **Batamanta ERTS Repository**! This project serves as a centralized, ready-to-use archive for pre-compiled Erlang Run-Time System (ERTS) binaries. 

If you want to skip the lengthy Erlang/OTP compilation process and get straight to building your Elixir/Erlang applications, you are in the right place.

---

## 🎯 Supported Platforms & Architectures

We provide pre-compiled binaries for the following targets:

* **macOS:** `aarch64` (Apple Silicon / M-series chips)
* **Linux (glibc):** `x86_64` & `aarch64` (Standard Ubuntu/Debian/etc.)
* **Linux (musl):** `x86_64` & `aarch64` (Alpine and other musl-based distros)

---

## 🚀 How to Use (via GitHub Releases)

To keep this repository lightweight and extremely fast to clone, **all binaries are hosted in GitHub Releases**, not in the git source tree. 

1. **Download:** Go to the [Releases](https://github.com/Lorenzo-SF/Batamanta---ERTS-repository/releases) page and grab the `.tar.gz` archive for your target OS and architecture from your desired OTP version.
2. **Extract:** Unzip the archive into your preferred directory (e.g., `~/.local/share/erts`).
3. **Update PATH:** Add the extracted `bin` directory to your system's PATH.

*Note: Our builds inject dynamic path discovery (`ROOTDIR` magic), so the ERTS will work seamlessly no matter where you extract it!*

**Example using Fish shell:**
```fish
# Extract the downloaded binary
mkdir -p ~/.local/share/erts/28.0
tar -xzf arm64-glibc.tar.gz -C ~/.local/share/erts/28.0

# Add it to your PATH
set -gx PATH ~/.local/share/erts/28.0/bin $PATH

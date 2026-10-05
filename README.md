# Rigsmith

Rig and animate 3D characters. Open a `.glb`, place a skeleton, skin it, pose it and
key it, or generate motion from a text prompt. Everything is saved back into the same
file. Rigsmith runs on macOS, Windows and Linux through Vulkan.



https://github.com/user-attachments/assets/d0544199-e109-434b-9f2e-6c0b603e99e3



## Download

Get the latest build from **[Releases](https://github.com/tonis2/rigsmith/releases/latest)**:

| Platform | File | How to run it |
|---|---|---|
| Linux | `Rigsmith-<version>-x86_64.AppImage` | Make it executable (`chmod +x`), then double-click it. |
| Windows | `Rigsmith-<version>-windows-x64.zip` | Portable: unzip anywhere and run `rigsmith.exe`. |
| macOS 26+ (Apple Silicon) | `Rigsmith-<version>-macos-arm64.dmg` | Drag Rigsmith to Applications. The app isn't notarized, so the first time, right-click it and choose **Open**. |

The first time it starts, Rigsmith copies its built-in animations to
`Documents/Rigsmith/animations`. They show up in the asset browser, and that is
where **Open** starts.

On Windows, if `rigsmith.exe` won't start, install the
[Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist).

## Features

- **Rigging**: place joints by hand, or fit a biped, quadruped or bird body plan to the mesh.
- **Joint limits**: keep joints inside natural ranges while you pose.
- **Skin weights**: simple automatic weights, which you can view and paint.
- **Animation player**: a timeline with looping, playback speed and additive layers.
- **Asset browser**: your folders of `.glb` clips and body plans, searchable, with a built-in library to start from.
- **Poses and keyframes**: key poses, auto-key, saved poses, and tweening between them.
- **Text to motion with Kimodo**: see below.
- **Works with AI agents**: a built-in MCP server lets an agent such as Claude rig, pose and animate alongside you.

## Text to motion (Kimodo)

Rigsmith runs NVIDIA's [Kimodo](https://huggingface.co/nvidia/Kimodo-SOMA-RP-v1.1) motion
model on your GPU through Vulkan, so text-to-motion works on macOS, Windows and Linux.
There's no Python or CUDA to install, only the model files.

1. Download the weights from Hugging Face:
   - **Text encoder**: [LocalAI-io/Llama-3-Kimodo-GGML](https://huggingface.co/LocalAI-io/Llama-3-Kimodo-GGML), the `Llama-3-Kimodo-*.gguf` file and its `tokenizer.gguf`.
   - **Motion model**: [LocalAI-io/Kimodo-SOMA-RP-v1.1-GGML](https://huggingface.co/LocalAI-io/Kimodo-SOMA-RP-v1.1-GGML).
     NVIDIA's original folder, [nvidia/Kimodo-SOMA-RP-v1.1](https://huggingface.co/nvidia/Kimodo-SOMA-RP-v1.1) with its `model.safetensors`, also works.
2. Put them in any folder, for example `~/models/kimodo/`.
3. In Rigsmith, open **File › Settings › AI**. Choose the text model `.gguf`, then the motion
   model (its `.gguf`, or the NVIDIA folder). Only set the tokenizer if it isn't next to the text model.
4. Open the **Generate** tab, describe the motion, and generate.

The weights have their own licenses: the NVIDIA Open Model License and the Llama 3 license.

## Using Rigsmith with AI agents (MCP)

Rigsmith serves its tools to MCP clients while it's open, on `http://127.0.0.1:8808/mcp`
by default (only your own machine can reach it). To connect an agent:

1. Open **File › Settings**. The MCP section shows the server's address.
2. Click **Copy client config** and paste it into your agent's MCP settings.

You can change the port there, and the change applies straight away. Setting it to `0` turns the server off.

## Building from source

You need [c3c](https://github.com/c3lang/c3c) 0.8.3, [Git LFS](https://git-lfs.com) for the
sample models, and a Vulkan driver. Windows and Linux use the system's driver; on macOS,
`setup.sh` fetches one.

```sh
git clone --recursive https://github.com/tonis2/rigsmith.git
cd rigsmith
git lfs pull
libs/three/setup.sh          # submodules, plus the macOS Vulkan driver
c3c build rigsmith
./build/rigsmith assets/animations/humanoid.glb
```

- **Tests**: `c3c test --test-noleak` (fast); `c3c test` (also checks for memory leaks).
- **Packages**: after a build, `packaging/package-{macos,linux,windows}.sh` produce the release
  files. Pushing a `v*` tag builds them all on GitHub Actions.

## License

See [LICENSE](LICENSE).

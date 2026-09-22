# forge-align — offline install (air-gapped linux-64)

This bundle contains a fully built conda environment (Python 3.11, OpenCV,
OpenImageIO, OpenColorIO, ffmpeg, forge-io, forge-align and, unless built
without it, CPU SuperPoint/LightGlue with model weights) packed with
[conda-pack](https://conda.github.io/conda-pack/). Nothing is downloaded at
install or run time.

Built and tested on Rocky Linux 9.5 (glibc 2.34); works on RHEL/Rocky/Alma 9
and newer x86_64 distros.

## Install

Copy `forge-align-offline-<version>-linux-64.tar` (and its `.sha256`) to the
machine, then:

```bash
sha256sum -c forge-align-offline-*-linux-64.tar.sha256
tar -xf forge-align-offline-*-linux-64.tar
cd forge-align-offline-*-linux-64
bash install_offline.sh --global
```

`install_offline.sh`:

1. Verifies the bundle checksums.
2. Unpacks the env into conda's envs dir as `forge-cv` (`$(conda info --base)/envs`,
   or `~/.conda/envs` if that isn't writable) and runs `conda-unpack`.
3. Runs a self-test: synthesises a plate/reference pair and solves it with
   SIFT, SIFT against a ProRes `.mov`, and SuperPoint.
4. Runs `install.sh --python <env>/bin/python` to deploy the Flame hook and
   write `~/.forge/config.yaml` (including the REDline / art-cmd probe).

Options:

| Option | Meaning |
|---|---|
| `--env NAME` | Env name under conda's envs dir (default `forge-cv`) |
| `--prefix DIR` | Unpack to an explicit directory instead (conda not needed) |
| `--force` | Replace an existing env at the target |
| `--skip-smoke` | Skip the self-test |
| `--global` | Deploy hook to `/opt/Autodesk/shared/python` |
| `--project PATH` | Deploy hook to a Flame project (repeatable) |

The config is per user (`~/.forge/config.yaml`). For other Flame users on the
same machine, point them at the same env without unpacking again:

```bash
bash install.sh --python /path/to/envs/forge-cv/bin/python --global
```

Then restart Flame (or evict the cached module and Rescan Python Hooks).

## Uninstall

```bash
bash uninstall.sh
```

## Re-run the self-test

```bash
/path/to/envs/forge-cv/bin/python smoke_offline.py
```

`env/conda-explicit.txt` and `env/pip-freeze.txt` list every package in the
env.

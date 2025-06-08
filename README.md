# sync_usb_to_ssd.sh

A chunked, resumable Bash script for safely syncing large amounts of data from a USB stick to an external SSD on systems with limited connectivity options and minimal internal disk space.

## 🧠 When to Use

This script is ideal if you:
- Can only connect one USB-C device at a time (e.g., only one USB-C to USB-A adapter)
- Need to copy a large USB stick to an SSD but **don’t have enough internal disk space** to stage it all at once
- Want a safe, robust, chunked solution that handles interruptions and retries

## ❌ When NOT to Use

Do **not** use this script if:
- You can connect both USB and SSD simultaneously — just use `rsync` directly.
- You have enough internal disk space to hold the full contents temporarily — a simple two-step manual copy will be faster.
- You want a strict mirror with deleted files — this script preserves unrelated files on the SSD by default.

## ✅ Features

- File-size based chunking (~3.5 GiB per chunk, configurable)
- Automatic retry per chunk (up to 2 times, configurable)
- Resumable (tracks progress with `.done` markers)
- Auto-unmounts devices before safe removal
- Supports quiet and verbose modes
- No destructive operations

## 🔧 Usage

Make the script executable:

```bash
chmod u+x sync_usb_to_ssd.sh
```

Run it with desired options:

```bash
./sync_usb_to_ssd.sh [--noresume] [--quiet] [--verbose]
```

## 🗂 Options

| Flag         | Description                                       |
|--------------|---------------------------------------------------|
| `--noresume` | Ignore progress and re-copy all chunks            |
| `--quiet`    | Suppress most output                              |
| `--verbose`  | Show full `rsync` output                          |
| `--help`     | Show help                                         |

## 📦 Output

The SSD will contain an exact copy of all files from the USB stick. Nothing is extracted — files are ready to use immediately. Unrelated files on the SSD are left untouched.

## 🔒 License

This script is provided under the MIT License (see [LICENSE](./LICENSE)).

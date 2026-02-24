# Starr-Taggers

Tagging scripts for the Starr apps.

## Radarr DV HDR Tagarr

Using `dovi_tool`, these scripts automatically tag your movies in Radarr based on their media file metadata. You can use these tags for various purposes, such as creating collections in Plex — with or without [Kometa](https://kometa.wiki/).

**Tags added:**

| Category      | Values                               |
|---------------|--------------------------------------|
| Color mapping | `CM2`, `CM4`                         |
| Profile       | `DV P8`                              |
| Layer type    | `MEL`, `FEL`                         |
| Video format  | `SDR`, `PQ`, `HDR10`, `HDR10+`, `DV` |

| Script                       | Description                                            |
|------------------------------|--------------------------------------------------------|
| `99-install_dependencies.sh` | Installs `dovi_tool` inside the container on startup   |
| `dv-hdr_tagarr_import.sh`    | Tags movies automatically on import                    |
| `dv-hdr_tagarr.sh`           | Standalone script to tag your existing movies manually |

---

## Installation

### 1. Set Up the Scripts

In your Radarr `appdata` directory:

1. Create a folder named `cont-init.d` and copy `99-install_dependencies.sh` into it.
2. Create a folder named `scripts` and copy the two remaining scripts into it.
3. Make all three files executable.
4. Open each script and fill in the required configuration values as described in the file comments.

**Example paths on unRAID:**

|           | Path                                                              |
|-----------|-------------------------------------------------------------------|
| Container | `/etc/cont-init.d/99-install_dependencies.sh`                     |
| Host      | `/mnt/user/appdata/radarr/cont-init.d/99-install_dependencies.sh` |

> [!NOTE]
> Enter the path directly — do not use a file picker to browse to it.

### 2. Restart Radarr

Restart your Radarr container so `dovi_tool` is installed on startup.

### 3. Configure a Custom Script in Radarr

Go to **Settings → Connect** and add a new **Custom Script** with the following settings:

- **Tags:** Leave empty
- **Path:** `/config/scripts/dv-hdr_tagarr_import.sh`

Enable these triggers:

- On File Import
- On File Upgrade
- On Movie File Delete
- On Movie File Delete For Upgrade

Click **Test**. If you see errors, check the following:

- Radarr URL is correct
- Radarr API key is correct
- Scripts are marked as executable
- `dovi_tool` is installed
- File permissions are correct
- File is saved with LF line endings, not CRLF

---

## Tag Your Existing Media

To tag movies you already have, run the standalone script from a terminal:

```bash
docker exec -it radarr /config/scripts/dv-hdr_tagarr.sh
```

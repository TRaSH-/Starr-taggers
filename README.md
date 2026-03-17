# Starr-Taggers

Tagging scripts for the Starr apps.

> [!NOTE]
> These scripts were not written by me. They were created by other developers on request. All credit goes to the original developers.

---

## Radarr DV HDR Tagarr

This script is based on the original [Tag DV FEL/MEL Script](https://github.com/mvanbaak/arr_scripts). All credit goes to the original developer.

**Features:**

Using [`dovi_tool`](https://github.com/quietvoid/dovi_tool), these scripts automatically tag your movies in Radarr based on each file's metadata. You can use these tags for many purposes — for example, building collections in Plex, with or without [Kometa](https://kometa.wiki/).

📖 See the [Wiki](https://github.com/TRaSH-/Starr-taggers/wiki#radarr-dv-hdr-tagarr) for setup instructions.

---

## Tagarr

Automated movie tagging for Radarr based on release groups.

Tagarr scans movies in one or two Radarr instances and tags them based on release group, quality source (MA/Play WEB-DL), and lossless audio codec (TrueHD, TrueHD Atmos, DTS-X, DTS-HD MA). It can also sync tags to a second Radarr instance and remove unused or empty tags.

**Features:**

- 📚 **Build smart collections** — filter your library by release group quality
- 👁️ **Track what you have** — see at a glance which movies came from premium groups
- ✅ **Filter by quality** — only tag releases that meet your audio and video standards
- 🔍 **Discover new groups** — automatically find new groups that pass your filters
- 🔄 **Sync across instances** — mirror tags between your HD and 4K Radarr setups
- 🛠️ **Recover release group info** (\*)

> [!IMPORTANT]
> Check the [original repo](https://github.com/ProphetSe7en/tagarr) for the most up-to-date scripts.

📖 See the [original repo](https://github.com/ProphetSe7en/tagarr) or the [Wiki](https://github.com/TRaSH-/Starr-taggers/wiki#tagarr-release-group) for setup instructions.

---

> (\*) **Release group recovery** requires Radarr to have a grab event in its history. Recovery will not work if the movie was imported manually (e.g. drag-and-drop or manual import), or if Radarr's history has been cleared — in both cases, the grab event no longer exists.
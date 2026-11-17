# Custom Magazines

Project Zomboid B42 image magazines. This mod needs Zombie Buddy 2.3.4 enabled on the game client and authoritative server. Version 0.3.7 allows pages to be viewed in any order before completion.

## Configure the image folder

On first launch the mod creates `Zomboid/Lua/CustomMagazinesPath.txt`. Put the absolute path to the image root on its first non-empty line, for example:

```text
D:\Photos\Magazines
```

Each direct child folder is one magazine. Put `.jpg`, `.jpeg`, `.png`, or `.webp` page images directly inside that folder. The root folder's loose images and nested folders are ignored. Pages are sorted by filename without regard to case. Animated WebP files display their first frame.

In multiplayer, configure the server and every client. Their configured roots may differ, but folder names and each folder's supported page filenames must match. The mod compares the ordered page filename list; it does not hash image bytes, so copy identical image contents to every machine. The server determines page count, loot, saved titles, and reading rewards.

## In game

- Right-click a custom magazine to read or rename it.
- Reading starts on the first filename-sorted image. The reader page's longer side is sized to two-thirds of the game viewport, with its aspect ratio preserved and the page centered. Only closing after viewing every page marks that folder as read and can grant a reward. Closing earlier aborts without marking read or granting a reward. A player receives the reward once per folder ID; rereading it never grants another reward.
- Opening the reader pauses game speed in single-player and restores the previous speed when it closes. Multiplayer cannot pause shared world time for one player, so reading does not pause the server or other players.
- WebP pages are decoded by the bundled pure-Java JWebP 0.2.0 library; animated WebP shows its first frame.
- Every ordinary B42 magazine loot pool is divided into two-thirds vanilla ordinary magazines and one-third custom magazines. Skill and recipe magazines are not changed.
- Custom magazine folder IDs are assigned without replacement within a persistent world cycle. A folder can be assigned again only after every currently valid folder ID has appeared in that cycle.
- The inventory and world item use the stock magazine mesh with the user-supplied pink rabbit-costume photo as its cover texture. The photo is packaged unchanged apart from JPEG-to-PNG re-encoding for the game's texture loader.
- 1–10 pages: reduce unhappiness/panic by 30 and stress by 0.30. 11–20 pages: reduce by 65 and 0.65. 21+ pages: clear all three stats. Stress uses the game's 0–1 scale; panic and unhappiness use 0–100.

Image folders are rescanned on startup and when a magazine is opened. If folders are added after a world starts, they can be read immediately, while their loot weight takes effect after restarting the world.

The Java helper only reads supported files under the configured root, rejects path traversal and symlinked entries, and releases the texture when the reader changes page or closes. It skips files larger than 64 MiB, images larger than 24 million pixels, and files that the installed Java image readers cannot decode.

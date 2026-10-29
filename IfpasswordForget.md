

Don't keep trying passwords. A root shell will let you set a new password, and it will also show us why the login fails. There are two likely causes:

- **You changed the password at the first login** and the new one isn't what you're typing now.
- **The first-boot setup never ran**, so the `ubuntu` account was never created. If so, no password would work.

This needs the SD card, a Windows PC and a keyboard on the Pi.

**1. Edit `cmdline.txt` on Windows**

1. Unplug the Pi and put the SD card in your PC.
2. Open the `system-boot` drive, then open `cmdline.txt` in Notepad. It's a single line.
3. At the end of that line, add a space and then `init=/bin/bash`, so the end reads `... rootwait fixrtc init=/bin/bash`. Keep it on the same line.
4. Save, eject the card, put it back in the Pi and power on.

**2. Set the password on the Pi**
It boots straight to a `#` prompt with no login (press Enter if you don't see it). Type:

```bash
mount -o remount,rw /
id ubuntu
```

- **If `id` prints `uid=1000(ubuntu) ...`**, the account exists and the password was changed. Run `passwd ubuntu` and type a new password twice. Nothing appears on screen while you type, which is normal. Letters and digits are safest.
- **If it prints `no such user`**, the first-boot setup didn't run. Create the account yourself:
  ```bash
  useradd -m -s /bin/bash -G adm,sudo ubuntu
  passwd ubuntu
  ls /etc/netplan
  ```

Then run `sync` and unplug the Pi. It can't shut down normally in this mode.

**3. Undo the edit**
Put the card back in your PC, remove ` init=/bin/bash` from `cmdline.txt`, save and eject. Boot the Pi normally and log in as `ubuntu` with your new password.

Please tell me what `id ubuntu` printed. If the account didn't exist, the first-boot setup also handles the network, so `ls /etc/netplan` will probably come back empty. In that case I'll need to work out why the setup didn't run on the 20.04 root and fix the build script, so the next image works without these steps.


I'm assuming you mean Ubuntu 24.04; there's no 24.05. Your system is two layers: the bottom half is 24.04 and the top half is 20.04.

| Layer                                                                                                     | Your system  | Ubuntu 24.04 on a Pi 5                       | Matters for power?                                                                                                             |
| --------------------------------------------------------------------------------------------------------- | ------------ | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Boot firmware, `config.txt`, device tree                                                                | from 24.04   | same                                         | yes, and identical                                                                                                             |
| Kernel `6.8.0-1064-raspi`: CPU frequency scaling, idle states, thermal throttling, fan control, drivers | from 24.04   | same (if 24.04 runs the same kernel version) | yes, and identical                                                                                                             |
| CPU governor                                                                                              | `ondemand` | `ondemand`                                 | identical. I checked both images: the kernel defaults to `ondemand`, and 20.04's `ondemand.service` also sets `ondemand` |
| Libraries, compiler, Python: glibc 2.31, GCC 9.4, Python 3.8                                              | from 20.04   | glibc 2.39, GCC 13, Python 3.12              | yes, through how much work the program does                                                                                    |
| Background services: systemd 245, snapd, etc.                                                             | from 20.04   | newer versions                               | slightly, through the idle baseline                                                                                            |

**Which system your results will be closer to depends on what you measure:**

* **Power draw in watts while the program runs: close to 24.04.** The hardware's power behaviour is set by the kernel, firmware and governor, and those are the same as 24.04.
* **Runtime, and so energy per run (watts × seconds): it depends on how the program is built.**
  * **The same binary on both systems** (statically linked, or built once and copied over): close to 24.04.
  * **Built with the system compiler, or using the system's Python or libraries:** it reflects 20.04's software. Older compilers and libraries can produce code that does more work for the same task, and Python 3.12 is often noticeably faster than 3.8. The run may take longer and use more energy than on 24.04 at similar wattage.

**Your results don't represent "real" Ubuntu 20.04 on a Pi 5,** because no such thing exists. The nearest real setup is 20.04 on a Pi 4 with kernel 5.4, which is different hardware. If you publish numbers, describe the setup as  *Ubuntu 20.04.5 userland on the Ubuntu 24.04 kernel 6.8.0-1064-raspi, Raspberry Pi 5* .

**To keep a comparison with 24.04 fair:**

1. Run the same kernel on both. Check `uname -r`, and don't let the 24.04 system upgrade its kernel during the tests.
2. Check the governor on both with `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`. You can set both to `performance` for more repeatable runs.
3. Use the same Pi, power supply, SD card and cooling, with nothing extra plugged in (no HDMI or USB devices). Start each run at a similar temperature (`cat /sys/class/thermal/thermal_zone0/temp`), because the Pi 5 slows itself down when it gets hot.
4. Measure the idle power of each system first and subtract it. Repeat each test several times.
5. Measure whole-board power with a USB-C power meter between the power supply and the Pi.

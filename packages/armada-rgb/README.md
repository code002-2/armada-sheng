# Armada RGB

`armada-rgb` controls RGB LEDs exposed through Linux's multicolor or individual
channel LED interfaces. It detects the device-tree model and loads the matching
hardware profile from `/usr/share/armada-rgb/profiles.json`.

The first version supports a solid color, brightness, persistent off, and
restoring the saved configuration:

```text
armada-rgb get
armada-rgb set --color FF8000 --brightness 25
armada-rgb off
armada-rgb apply
armada-rgb supported
```

Settings are saved to `/etc/armada/rgb.json` after the hardware was
updated successfully. Only LED names declared by the matched profile are used.
Profiles using the `channels` backend provide explicit target mappings such as
`red=l:r1`.

Profiles can provide conditional red, green, and blue channel reductions. The
saved correction can be changed with `armada-rgb set --correction`.

The versioned catalog groups exact device-tree model names with a `channels` or
`multicolor` backend, its target list, and an optional default correction.

For tests, the profile catalog and device model paths can be overridden with
`ARMADA_RGB_PROFILES_PATH` and `ARMADA_RGB_MODEL_PATH`.

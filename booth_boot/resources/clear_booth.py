import board

from photobooth import RPi

booth = RPi()

panel = booth.add_neopixel(name="main", control=board.D18)
panel.clear()

booth.clear_components()
booth.clear_leds()

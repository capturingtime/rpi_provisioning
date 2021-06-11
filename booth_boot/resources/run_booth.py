"""
"""
import board
import time
import os
import string
import random
import argparse

from photobooth import RPi
from pyzenfolio import PyZenfolio
from datetime import date
from multiprocessing import Manager

max_prints = 3
booth_dir = '/opt/booth_images'
zen_profile_name = 'capturingtime'
default_shot_data = {'name': None,
                     'print_n': 0,
                     'url': None,
                     'pw': None,
                     'path': None,
                     'uploaded': False}


def pw_gen():
    char = string.ascii_lowercase + string.digits
    for x in "aeiou":
        char = char.replace(x, '')
    return ''.join(random.sample(char, 10))


parser = argparse.ArgumentParser()
parser.add_argument("-u", "--username", dest='username', help="Zenfolio username")
parser.add_argument("-p", "--password", dest='password', help="Zenfolio password")
parser.add_argument("-x", "--upload",  dest='upload', help="Enable Uploading", action="store_true")
parser.set_defaults(upload=False)
args = parser.parse_args()


class PhotoBooth():
    def __init__(self, zen_user=None, zen_pass=None, upload=None):
        self._zen_user = zen_user if zen_user else None
        self._zen_pass = zen_pass if zen_pass else None
        self._zen_upload = upload if upload is not None else None

        self.today = str(date.today())
        self.net_local = False
        self.net_www = False
        self._shot_data = Manager().dict()  # So data can be updated in threads
        self._startup()
        self._init_zenfolio()
        self.attract = self.rpi.run_as_thread(self.panel.scroll, start=True, speed=0.01,
                                              text="Press the big blue button to begin!  ",)
        print("Booth is online and ready")

    def shot_data(self):
        return dict(self._shot_data)

    def _init_zenfolio(self):
        """ initialize zenfolio API
        """
        # If upload is false, don't init.
        if not self._zen_upload:
            return False

        if self.net_www and self._zen_user and self._zen_pass:
            init_scroll = self.rpi.run_as_thread(self.panel.scroll, start=True, speed=0.01,
                                                 text="Initializing Zen API, Please wait...",)
            auth = {'username': self._zen_user, 'password': self._zen_pass}
            self.zen_api = PyZenfolio(auth=auth)
            self.zen_api.Authenticate()
            self.zen_api.profile = self.zen_api.LoadPublicProfile(username=zen_profile_name)
            root_group_id = self.zen_api.profile.RootGroup.Id
            self.zen_api.root_grp = self.zen_api.LoadGroupHierarchy(username=zen_profile_name)

            found = False
            for g in self.zen_api.root_grp.Elements:
                if g.Title == "Events":
                    event_grp_id = g.Id
                    found = True

            if not found:
                print("Events Group doesn't exist, creating...")
                group = {'Title': 'Events'}
                result = self.zen_api.CreateGroup(parent_id=root_group_id, group=group)
                event_grp_id = result.Id
                flags = "NoPublicSearch"
                access = {'AccessType': 'Private', 'IsDerived': False, 'AccessMask': flags}
                self.zen_api.UpdateGroupAccess(group_id=event_grp_id, group_access=access)

            self.zen_api.event_grp = self.zen_api.LoadGroup(id=event_grp_id, recursive=True)

            found = False
            for g in self.zen_api.event_grp.Elements:
                if g.Title == "Booth":
                    booth_grp_id = g.Id
                    found = True

            if not found:
                print("Booth Group doesn't exist, creating...")
                group = {'Title': 'Booth'}
                result = self.zen_api.CreateGroup(parent_id=event_grp_id, group=group)
                booth_grp_id = result.Id
                flags = "ProtectOriginals"
                access = {'AccessType': 'Private', 'IsDerived': False, 'AccessMask': flags}
                self.zen_api.UpdateGroupAccess(group_id=booth_grp_id, group_access=access)

            self.zen_api.booth_grp = self.zen_api.LoadGroup(id=booth_grp_id, recursive=True)

            found = False
            for p in self.zen_api.booth_grp.Elements:
                if p.Title == self.today:
                    booth_gallery_id = p.Id
                    found = True

            if not found:
                print("Booth Gallery doesn't exist, creating...")
                gallery = {'Title': f'{self.today}', 'CustomReference': f'events/{self.today}'}
                result = self.zen_api.CreatePhotoSet(group_id=booth_grp_id,
                                                     photoset=gallery)
                booth_gallery_id = result.Id
                access = {'AccessType': 'Password', 'Password': pw_gen(), 'IsDerived': False}
                self.zen_api.UpdatePhotoSetAccess(photoset_id=booth_gallery_id,
                                                  photoset_access=access)

            self.zen_api.booth_gallery = self.zen_api.LoadPhotoSet(set_id=booth_gallery_id,
                                                                   with_photos=False)

            init_scroll.stop_immediately()
            print("Zenfolio API Initialized")
            return True

    def _startup(self):
        """ Run startup Tasks
        """
        self.rpi = RPi()

        print("starting webserver")
        self.rpi.start_web()

        while not self.rpi.check_web():
            time.sleep(0.05)
        print("Webserver started")

        print("starting kiosk")
        self.rpi.start_kiosk()
        self.rpi.reset_last_shot()

        print("setting up components and running checks")
        self.panel = self.rpi.add_neopixel(name="main", control=board.D18)
        panel_test = self.rpi.run_as_thread(self.panel.panel_test, executions=1, start=True)

        self.camera = self.rpi.add_camera(name="main", model="Canon EOS 1100D")
        self.rpi.toggle_led(label="camera_rdy", on=True)

        self.printer = self.rpi.add_printer(name="receipt", model="PBM-8350U")
        self.rpi.toggle_led(label="print_rdy", on=True)

        # TODO: run these checks as a thread and check periodically?
        if self.rpi.net_check_local():
            self.net_local = True
            self.rpi.toggle_led(label="net_local", on=True)

        if self.rpi.net_check_www():
            self.net_www = True
            self.rpi.toggle_led(label="net_www", on=True)

        while panel_test.is_alive():
            time.sleep(0.05)

        print("Booth is initialized")
        self.rpi.toggle_led(label="shutter_rdy", on=True)

        self.last_shot_ts = 0
        self.last_print_ts = 0
        self.last_show_ts = 0

    def show_last_shot(self):
        """ Displays the last shot taken as long as its been less than 3 minutes since it was taken.
        """
        print("Last Shot button pressed")
        now = time.time()

        try:
            delta = int(now - self.last_show_ts)
        except Exception:
            # There probably wasn't any 'last' shown, so do nothing
            pass
        else:
            # If its been less than (seconds) then its still displaying it, so just ignore
            if delta <= 5:
                return None

        # Check if we had a shot in the last 3 minutes
        try:
            delta = int(now - self.last_shot_ts)  # noqa: F821
        except Exception:
            # There probably wasn't a shot taken yet, so do nothing
            return None
        else:
            # If its been more than (seconds), reset the last shot because its probably not theirs
            if delta >= 180:
                self.rpi.reset_last_shot()

        self.last_show_ts = time.time()
        self.rpi.display_last_shot()

        return True

    def print_receipt(self, shot_name: str = None):
        """ Prints out a receipt that can be used to get a digital copy or print later
        """

        last_shot = self.camera.last_shot()
        if not last_shot:
            print("Print button pressed, but no 'last_shot' exists. Skipping Print.")
            return False

        if not shot_name:
            shot_name = os.path.split(last_shot)[-1]

        print("Print button was pressed")
        now = time.time()
        # Check if we had a recent print
        try:
            delta = int(now - self.last_print_ts)
        except Exception:
            # There probably wasn't a last_print, so go ahead
            pass
        else:
            # Only print if we haven't in the last 3 seconds (successive pushes)
            if delta <= 3:
                return False  # don't print

        # Check how many times this shot had a receipt printed (limit kids pushing buttons)
        shot_data = self.shot_data()
        shot = shot_data.get(shot_name, None)
        # make sure it exists
        if not shot:
            print(f"Attempting to print {shot_name} but it doesn't exist in 'self.shot_data'")
            return False

        if shot['print_n'] >= max_prints:
            print(f"Max prints ({max_prints}) exceeded for "
                  f"{shot_name} ({shot['print_n']})")
            self.panel.flash(text="Max Prints exceeded for this shot, Sorry. :(")
            return False

        self.attract.stop_immediately()

        print(f"Printing receipt for {shot_name}")
        self.rpi.run_as_thread(self.panel.flash, text="Printing...   ", executions=1, start=True)
        while not self.camera.is_ready():
            time.sleep(0.01)  # wait for camera to be ready after the shot.

        # TODO: When auto updating is built:
        #   allow the messaging to be easily changed for event customizing

        # Print width is 48 characters
        self.printer.text(text="Thank you for using our photobooth!")
        self.printer.ln()
        self.printer.text(text="Please visit us at http://capturingtimephoto.net")
        self.printer.ln()
        self.printer.ln()
        self.printer.text(text="Mention this photobooth when you book your next "
                          "session with us & receive an extra 10% discount!")
        self.printer.ln()
        self.printer.ln()
        # Check if a photo was uploaded and print accordingly
        if shot['uploaded']:
            self.printer.text(text="Visit the URL below to order a free copy of this")
            self.printer.ln()
            self.printer.text(text="photo that you can share with others.")
            self.printer.ln()
            self.printer.qr(content=f"{shot['url']}", size=10)
            self.printer.ln()
            self.printer.text(text=f"Photo URL: {shot['url']}")
            self.printer.ln()
            self.printer.text(text=f"Access Password: {shot['pw']}")
            self.printer.ln()
            self.printer.ln()
        else:
            self.printer.text(text="To order your free copy of this photo;")
            self.printer.ln()
            self.printer.text(text="Please contact us at contact@capturingtimephoto.net")
            self.printer.ln()
            self.printer.text(text="and provide us with the photo name below.")
            self.printer.ln()
            self.printer.ln()
            self.printer.text(text=f"Photo name: {shot['name']}")
            self.printer.ln()
            self.printer.ln()

        self.printer.text(text="Tag us on Instagram: @capturingtimephoto")
        self.printer.ln()
        self.printer.text(text="Tweet at us on Twitter: @capturing_time")
        self.printer.cut()

        self.last_print_ts = time.time()
        shot['print_n'] += 1

        # record data changes
        self._shot_data.update(shot_data)

        self.attract.restart()
        return True

    def capture(self, camera: object = None, upload: bool = True):
        """ Uses a camera to capture a shot
        """
        self.attract.stop_immediately()
        panel = self.panel
        # If we didn't get a camera, use the default.
        if not camera or not isinstance(camera, object):
            camera = self.camera

        print("Capture button was pressed")
        panel.scroll(text="3...")
        panel.scroll(text="2...")
        panel.scroll(text="1...  Smile! :D")
        _capture = self.rpi.run_as_thread(target=camera.capture, executions=1, start=True)
        wait = self.rpi.run_as_thread(target=panel.twinkle, start=True, count=20)
        while _capture.is_alive():
            time.sleep(0.01)
        self.last_shot_ts = time.time()
        last_shot = camera.last_shot()
        shot_name = os.path.split(last_shot)[-1]
        wait.stop_immediately()
        awesome = self.rpi.run_as_thread(self.panel.flash, text="AWESOME!", executions=1, start=True)  # noqa: E501
        self.rpi.copy_to_last_shot(last_shot)

        self.last_show_ts = time.time()
        self.rpi.display_last_shot()

        camera.copy_last_shot_to_dir(dir=booth_dir)

        shot_data = self.shot_data()
        shot_data[shot_name] = {**default_shot_data}
        shot = shot_data[shot_name]

        shot['name'] = shot_name
        shot['path'] = last_shot

        if upload:
            self.rpi.run_as_thread(self.upload_booth_shot, executions=1, start=True)

        # record data changes
        self._shot_data.update(shot_data)

        while awesome.is_alive():
            time.sleep(0.01)
        self.attract.restart()
        return shot_name

    def upload_booth_shot(self, shot_name: str = None):
        """ uploads the shot to zenfolio if it doesn't exist. (by name)
        """
        if not getattr(self, 'zen_api', None):
            return None

        if not shot_name:
            shot_name = os.path.split(self.camera.last_shot())[-1]

        shot_data = self.shot_data()
        shot = shot_data.get(shot_name, None)

        if not shot:
            return False

        booth_gallery = self.zen_api.booth_gallery

        print(f"uploading {shot['path']} to Zenfolio")
        photo_id = self.zen_api.UploadPhoto(booth_gallery, path=shot['path'])
        photo_pw = pw_gen()
        access = {'AccessType': 'Password', 'Password': photo_pw, 'IsDerived': False}
        self.zen_api.UpdatePhotoAccess(photo_id, access)

        photo = self.zen_api.LoadPhoto(photo_id, info_level='Level1')

        shot['pw'] = photo_pw
        shot['url'] = photo.PageUrl
        shot['uploaded'] = True

        # record data changes
        self._shot_data.update(shot_data)

        return True


if __name__ == "__main__":
    booth = PhotoBooth(zen_user=getattr(args, 'username', None),
                       zen_pass=getattr(args, 'password', None),
                       upload=getattr(args, 'upload', None))

    while True:
        time.sleep(0.01)

        if booth.rpi.check_sw_input("capture"):
            booth.capture()

        elif booth.rpi.check_sw_input("print"):
            booth.print_receipt()

        elif booth.rpi.check_sw_input("last_shot"):
            booth.show_last_shot()

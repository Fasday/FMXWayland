// Test helper of tests/compositors.sh: GNOME Shell's unsafe mode, so the test can call org.gnome.Shell.Eval (input
// through Clutter virtual devices, window queries) and org.gnome.Shell.Screenshot; no overview after the startup
// animation (it would take the input meant for the windows). Only for a private test session.
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class FmxwTestExtension extends Extension {
    enable() {
        global.context.unsafe_mode = true;
        this._startup = Main.layoutManager.connect('startup-complete', () => Main.overview.hide());
        if (!Main.layoutManager._startingUp)
            Main.overview.hide();
    }

    disable() {
        Main.layoutManager.disconnect(this._startup);
        global.context.unsafe_mode = false;
    }
}

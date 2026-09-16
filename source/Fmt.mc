import Toybox.Lang;
import Toybox.System;

// Formatting helpers and the semantic color rules (bull / bear only).
module Fmt {
    function hours(c as System.ClockTime) as String {
        var h = c.hour;
        if (System.getDeviceSettings().is24Hour) {
            return h.format("%02d");
        }
        h = h % 12;
        if (h == 0) { h = 12; }
        return h.toString();
    }

    function time(c as System.ClockTime) as String {
        return hours(c) + ":" + c.min.format("%02d");
    }

    function num(v as Number?) as String {
        return (v == null) ? "--" : v.toString();
    }

    // Rail cells fit four glyphs of the value font: 842, 6.4K, 12K.
    function thousands(v as Number?) as String {
        if (v == null) { return "--"; }
        if (v < 1000) { return v.toString(); }
        if (v < 10000) { return (v / 1000).toString() + "." + ((v % 1000) / 100).toString() + "K"; }
        return (v / 1000).toString() + "K";
    }

    // Calories burned: shown as the exact integer (e.g. 850, 2345). A day's burn stays within four
    // digits, which fits the rail cell in the tabular value font.
    function kcal(v as Number?) as String {
        return (v == null) ? "--" : v.toString();
    }

    function mmss(sec as Number?) as String {
        if (sec == null || sec <= 0) { return "--"; }
        return (sec / 60).toString() + ":" + (sec % 60).format("%02d");
    }

    // minutes -> whole hours, rounded up (REC 18H)
    function hoursUp(min as Number) as Number {
        return (min + 59) / 60;
    }

    // Body Battery: >= 80 go heavy (bull), < 30 recover (bear), else accent.
    function bbColor(bb as Number?) as Number {
        if (bb == null) { return Theme.ACCENT; }
        if (bb < 30)  { return Theme.BEAR; }
        if (bb >= 80) { return Theme.BULL; }
        return Theme.ACCENT;
    }

    // Garmin's verdict on cumulative load, rendered as bull / bear.
    function statusColor(s as String) as Number {
        if (s.equals("PRODUCTIVE") || s.equals("PEAKING")) { return Theme.BULL; }
        if (s.equals("UNPRODUCTIVE") || s.equals("OVERREACHING") || s.equals("DETRAINING")) { return Theme.BEAR; }
        return Theme.ACCENT;
    }
}

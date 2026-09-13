import Toybox.Application;
import Toybox.Complications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Lifecycle + drawing only. Data lives in Metrics, coordinates in Layout, tokens in Theme.
class FanFaceView extends WatchUi.WatchFace {
    private var _m as Metrics;
    private var _l as Layout?;
    private var _lowPower as Boolean = false;
    private var _burnIn as Boolean = false;
    private var _showSeconds as Boolean = true;
    private var _pressedCell as Number = -1;

    // Bitmap fonts (resources/fonts). System fonts are placeholders until onLayout.
    private var _fTimeLight as FontType = Graphics.FONT_NUMBER_HOT;   // time
    private var _fValue as FontType = Graphics.FONT_MEDIUM;           // rail values
    private var _fSec as FontType = Graphics.FONT_SMALL;              // seconds
    private var _fMono26 as FontType = Graphics.FONT_TINY;            // date, coach line
    private var _fMono22 as FontType = Graphics.FONT_XTINY;           // rail labels, footer, battery row

    function initialize() {
        WatchFace.initialize();
        var ds = System.getDeviceSettings();
        _burnIn = (ds has :requiresBurnInProtection) && ds.requiresBurnInProtection;
        _m = new Metrics();
        reloadSettings();
    }

    function reloadSettings() as Void {
        var v = null;
        try {
            v = Application.Properties.getValue("showSeconds");
        } catch (e) {
        }
        _showSeconds = (v instanceof Boolean) ? (v as Boolean) : true;
    }

    function onLayout(dc as Dc) as Void {
        _l = new Layout(dc.getWidth(), dc.getHeight());
        _fTimeLight = WatchUi.loadResource(Rez.Fonts.LF_Light_112) as FontResource;
        _fValue     = WatchUi.loadResource(Rez.Fonts.LF_Semi_42)   as FontResource;
        _fSec       = WatchUi.loadResource(Rez.Fonts.Mono_30)      as FontResource;
        _fMono26    = WatchUi.loadResource(Rez.Fonts.Mono_26)      as FontResource;
        _fMono22    = WatchUi.loadResource(Rez.Fonts.Mono_22)      as FontResource;
    }

    function onShow() as Void {
        _m.refreshOnWake();
    }

    function onEnterSleep() as Void {
        _lowPower = true;
        WatchUi.requestUpdate();
    }

    function onExitSleep() as Void {
        _lowPower = false;
        _m.refreshOnWake();
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var l = _l as Layout;
        var clock = System.getClockTime();
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }

        if (_lowPower && _burnIn) {
            dc.setColor(Theme.AOD_BG, Theme.AOD_BG);
            dc.clear();
            drawAod(dc, l, clock);
            return;
        }

        dc.setColor(Theme.PAGE, Theme.PAGE);
        dc.clear();
        _m.refreshSlow(clock.min);
        drawRing(dc, l);
        drawDate(dc, l);
        drawTime(dc, l, clock);
        drawCoachLine(dc, l);
        drawRail(dc, l);
        drawFooter(dc, l);
        _pressedCell = -1;
    }

    // Tap on a rail cell -> open the native glance for that metric (Phase 5).
    function onFaceTap(x as Number, y as Number) as Boolean {
        var l = _l;
        if (l == null) { return false; }
        var cell = l.cellAt(x, y);
        if (cell < 0) { return false; }
        _pressedCell = cell;
        WatchUi.requestUpdate();
        var type = Complications.COMPLICATION_TYPE_CALORIES;
        if (cell == 0) { type = Complications.COMPLICATION_TYPE_HEART_RATE; }
        if (cell == 1) { type = Complications.COMPLICATION_TYPE_BODY_BATTERY; }
        return _m.open(type);
    }

    // ---- Always-on: Light digits only, receded tone, black canvas, micro-shifted 1 px/min ----
    private function drawAod(dc as Dc, l as Layout, c as System.ClockTime) as Void {
        var dx = (c.min % 3) - 1;
        var dy = ((c.min / 3) % 3) - 1;
        dc.setColor(Theme.ACCENT_2, Graphics.COLOR_TRANSPARENT);
        dc.drawText(l.cx + dx, l.cy + dy, _fTimeLight, Fmt.time(c),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---- Ring: weekly intensity minutes vs goal, ACCENT on LINE track, full ring in BULL ----
    private function drawRing(dc as Dc, l as Layout) as Void {
        var pct = 0.0;
        var goal = _m.intensityGoal;
        var done = _m.intensityMin;
        if (done != null && goal != null && goal > 0) {
            pct = done.toFloat() / goal;
        }
        dc.setPenWidth(3);
        dc.setColor(Theme.LINE, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(l.cx, l.cy, l.r);
        if (pct >= 1.0) {
            dc.setColor(Theme.BULL, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(l.cx, l.cy, l.r);
        } else if (pct > 0.0) {
            // drawArc: 0 deg = 3 o'clock, positive = counter-clockwise. Start at 12, sweep clockwise.
            var end = 90 - (360.0 * pct).toNumber();
            if (end < 0) { end += 360; }
            dc.setColor(Theme.ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(l.cx, l.cy, l.r, Graphics.ARC_CLOCKWISE, 90, end);
        }
        dc.setPenWidth(1);
    }

    private function drawDate(dc as Dc, l as Layout) as Void {
        var g = Gregorian.info(Time.now(), Time.FORMAT_MEDIUM);
        var s = (g.day_of_week as String).toUpper() + " · " + (g.month as String).toUpper() + " " + g.day;
        dc.setColor(Theme.MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(l.cx, l.yDate, _fMono26, s, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---- Time: Libre Franklin Light, hours and minutes in one weight. ----
    // The time and seconds fonts are digits-only with no descender, so aligning bottoms aligns baselines.
    private function drawTime(dc as Dc, l as Layout, c as System.ClockTime) as Void {
        var hh = Fmt.hours(c) + ":";
        var mm = c.min.format("%02d");
        var wH = dc.getTextWidthInPixels(hh, _fTimeLight);
        var wM = dc.getTextWidthInPixels(mm, _fTimeLight);
        var hT = dc.getFontHeight(_fTimeLight);
        var x0 = l.cx - (wH + wM) / 2;
        var yTop = l.yTime - hT / 2;

        dc.setColor(Theme.INK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x0, yTop, _fTimeLight, hh + mm, Graphics.TEXT_JUSTIFY_LEFT);

        if (_showSeconds && !_lowPower) {
            var hS = dc.getFontHeight(_fSec);
            dc.setColor(Theme.ACCENT_2, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x0 + wH + wM + l.secGap, yTop + hT - hS, _fSec, c.sec.format("%02d"), Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    // ---- Coach line "PRODUCTIVE · REC 18H": header sitting just above the stats panel ----
    private function drawCoachLine(dc as Dc, l as Layout) as Void {
        var status = (_m.trainingStatus != null) ? (_m.trainingStatus as String).toUpper() : "--";
        var recMin = _m.recoveryMin;
        var recReady = (recMin != null && recMin <= 0);
        var rec = "--";
        if (recMin != null) {
            rec = recReady ? "READY" : Fmt.hoursUp(recMin).toString() + "H";
        }

        var parts  = [status, " · REC ", rec] as Array<String>;
        var colors = [Fmt.statusColor(status), Theme.MUTED, recReady ? Theme.BULL : Theme.MUTED] as Array<Number>;
        var total = 0;
        for (var i = 0; i < parts.size(); i++) {
            total += dc.getTextWidthInPixels(parts[i], _fMono26);
        }
        var x = l.cx - total / 2;
        for (var i = 0; i < parts.size(); i++) {
            dc.setColor(colors[i], Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, l.yCoach, _fMono26, parts[i], Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
            x += dc.getTextWidthInPixels(parts[i], _fMono26);
        }
    }

    // ---- Stats panel: value over label in three cells, framed by visible 2 px GRID rules. ----
    // The top rule also underlines the coach line, so the lower third reads as one crisp block.
    private function drawRail(dc as Dc, l as Layout) as Void {
        dc.setColor(Theme.GRID, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(l.railX0, l.railTop,    l.railX1, l.railTop);
        dc.drawLine(l.railX0, l.railBottom, l.railX1, l.railBottom);
        // verticals inset a few px from the rules so the corners read as a drawn frame, not a box
        var inset = (l.h * 0.012).toNumber();
        dc.drawLine(l.railV0, l.railTop + inset, l.railV0, l.railBottom - inset);
        dc.drawLine(l.railV1, l.railTop + inset, l.railV1, l.railBottom - inset);
        dc.setPenWidth(1);

        cell(dc, l, 0, "HR",   Fmt.num(_m.hr),          Theme.ACCENT);
        cell(dc, l, 1, "BODY", Fmt.num(_m.bodyBattery), Fmt.bbColor(_m.bodyBattery));
        cell(dc, l, 2, "CAL",  Fmt.kcal(_m.calories),   Theme.ACCENT);
    }

    private function cell(dc as Dc, l as Layout, i as Number, label as String, value as String, color as Number) as Void {
        var x = l.xCells[i];
        dc.setColor((i == _pressedCell) ? Theme.ACCENT_HI : color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, l.yValue, _fValue, value, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Theme.MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, l.yLabel, _fMono22, label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // ---- Footer: VO2 / 5K, then the timeline "now" dot + battery + notifications, centered as a group ----
    private function drawFooter(dc as Dc, l as Layout) as Void {
        var s = "VO2 " + Fmt.num(_m.vo2Run) + " · 5K " + Fmt.mmss(_m.pred5kSec);
        dc.setColor(Theme.MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(l.cx, l.yFooter, _fMono22, s, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var b = _m.batteryPct.toString() + "%";
        if (_m.notifications > 0) {
            b += " · " + _m.notifications.toString();
        }
        var wB = dc.getTextWidthInPixels(b, _fMono22);
        var x0 = l.cx - (l.dotSize + l.dotGap + wB) / 2;
        var dotX = x0 + l.dotSize / 2;

        // .tl__item--now: filled ACCENT dot with ACCENT_DIM halo when the phone is linked; hollow ring when not
        if (_m.phoneConnected) {
            dc.setColor(Theme.ACCENT_DIM, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(dotX, l.yBattery, l.dotSize / 2);
            dc.setColor(Theme.ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(dotX, l.yBattery, l.dotSize / 4);
        } else {
            dc.setColor(Theme.ACCENT, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(dotX, l.yBattery, l.dotSize / 4);
        }
        dc.setColor((_m.batteryPct <= 15) ? Theme.BEAR : Theme.MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x0 + l.dotSize + l.dotGap, l.yBattery, _fMono22, b, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

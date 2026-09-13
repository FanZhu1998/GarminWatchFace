import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Complications;
import Toybox.Lang;
import Toybox.System;
import Toybox.UserProfile;

// Data layer.
//  - Complications push system-computed metrics (HR, Body Battery, Recovery, VO2max run,
//    Training Status, 5K prediction) into cached fields.
//  - ActivityMonitor / System are pulled at most once per minute (refreshSlow).
//  - UserProfile is pulled on wake (refreshOnWake).
// Anything unavailable stays null and the view renders "--".
class Metrics {
    // pushed by complications
    public var hr as Number?;
    public var bodyBattery as Number?;
    public var recoveryMin as Number?;
    public var vo2Run as Number?;
    public var trainingStatus as String?;
    public var pred5kSec as Number?;

    // pulled once per minute / on wake
    public var steps as Number?;
    public var stepGoal as Number?;
    public var calories as Number?;
    public var intensityMin as Number?;
    public var intensityGoal as Number?;
    public var restingHr as Number?;
    public var batteryPct as Number = 0;
    public var phoneConnected as Boolean = false;
    public var notifications as Number = 0;

    private var _ids as Dictionary<Complications.Type, Complications.Id> = {} as Dictionary<Complications.Type, Complications.Id>;
    private var _lastMinute as Number = -1;

    function initialize() {
        if (Toybox has :Complications) {
            Complications.registerComplicationChangeCallback(method(:onComplicationChanged));
            subscribe(Complications.COMPLICATION_TYPE_HEART_RATE);
            subscribe(Complications.COMPLICATION_TYPE_BODY_BATTERY);
            subscribe(Complications.COMPLICATION_TYPE_RECOVERY_TIME);
            subscribe(Complications.COMPLICATION_TYPE_VO2MAX_RUN);
            subscribe(Complications.COMPLICATION_TYPE_TRAINING_STATUS);
            subscribe(Complications.COMPLICATION_TYPE_RACE_PREDICTOR_5K);
        }
    }

    // Seed with the current value, then subscribe. A metric the device lacks throws
    // ComplicationNotFoundException and simply stays null.
    private function subscribe(type as Complications.Type) as Void {
        try {
            var id = new Complications.Id(type);
            _ids[type] = id;
            apply(type, Complications.getComplication(id).value);
            Complications.subscribeToUpdates(id);
        } catch (e) {
        }
    }

    // ComplicationChangedCallback: fires in low power too; the next tick draws the new value.
    function onComplicationChanged(id as Complications.Id) as Void {
        var keys = _ids.keys();
        for (var i = 0; i < keys.size(); i++) {
            var type = keys[i];
            if (id.equals(_ids[type])) {
                try {
                    apply(type, Complications.getComplication(id).value);
                } catch (e) {
                }
                return;
            }
        }
    }

    private function apply(type as Complications.Type, v as Object?) as Void {
        if (type == Complications.COMPLICATION_TYPE_HEART_RATE) {
            hr = toNum(v);
        } else if (type == Complications.COMPLICATION_TYPE_BODY_BATTERY) {
            bodyBattery = toNum(v);
        } else if (type == Complications.COMPLICATION_TYPE_RECOVERY_TIME) {
            recoveryMin = toNum(v);
        } else if (type == Complications.COMPLICATION_TYPE_VO2MAX_RUN) {
            vo2Run = positive(toNum(v));
        } else if (type == Complications.COMPLICATION_TYPE_TRAINING_STATUS) {
            trainingStatus = (v instanceof String) ? (v as String) : null;
        } else if (type == Complications.COMPLICATION_TYPE_RACE_PREDICTOR_5K) {
            pred5kSec = positive(toNum(v));
        }
    }

    private function toNum(v as Object?) as Number? {
        if (v instanceof Number) { return v; }
        if (v instanceof Float || v instanceof Long || v instanceof Double) { return (v as Numeric).toNumber(); }
        return null;
    }

    // A zero VO2max or race prediction means "not computed yet", not a value.
    private function positive(v as Number?) as Number? {
        return (v != null && v > 0) ? v : null;
    }

    // Called from onUpdate; does real work only when the minute changes.
    function refreshSlow(minute as Number) as Void {
        if (minute == _lastMinute) { return; }
        _lastMinute = minute;

        var info = ActivityMonitor.getInfo();
        steps = info.steps;
        stepGoal = info.stepGoal;
        calories = (info has :calories) ? info.calories : null;
        var am = info.activeMinutesWeek;
        intensityMin = (am != null) ? am.total : null;
        intensityGoal = info.activeMinutesWeekGoal;
        if (recoveryMin == null && (info has :timeToRecovery) && info.timeToRecovery != null) {
            recoveryMin = (info.timeToRecovery as Number) * 60;   // fallback: hours -> minutes
        }

        var stats = System.getSystemStats();
        batteryPct = stats.battery.toNumber();
        var ds = System.getDeviceSettings();
        phoneConnected = ds.phoneConnected;
        notifications = ds.notificationCount;

        if (hr == null) { hr = fallbackHr(); }
    }

    // Called from onShow / onExitSleep only.
    function refreshOnWake() as Void {
        var p = UserProfile.getProfile();
        restingHr = p.restingHeartRate;
        if (vo2Run == null && (p has :vo2maxRunning) && p.vo2maxRunning != null) {
            vo2Run = p.vo2maxRunning;
        }
        _lastMinute = -1;   // force a slow refresh on the next onUpdate
    }

    private function fallbackHr() as Number? {
        var ai = Activity.getActivityInfo();
        if (ai != null && ai.currentHeartRate != null) { return ai.currentHeartRate; }
        var it = ActivityMonitor.getHeartRateHistory(1, true);
        var s = it.next();
        if (s != null && s.heartRate != ActivityMonitor.INVALID_HR_SAMPLE) { return s.heartRate; }
        return null;
    }

    // Tap-to-open: launch the native glance for a complication type. Returns true if launched.
    function open(type as Complications.Type) as Boolean {
        if (!(Complications has :exitTo)) { return false; }
        try {
            var id = _ids.hasKey(type) ? (_ids[type] as Complications.Id) : new Complications.Id(type);
            Complications.exitTo(id);
            return true;
        } catch (e) {
            return false;
        }
    }
}

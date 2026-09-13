import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class FanFaceApp extends Application.AppBase {
    private var _view as FanFaceView?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var view = new FanFaceView();
        _view = view;
        return [ view, new FanFaceDelegate(view) ];
    }

    // App settings changed from Connect IQ mobile / Garmin Express.
    function onSettingsChanged() as Void {
        var v = _view;
        if (v != null) { v.reloadSettings(); }
        WatchUi.requestUpdate();
    }
}

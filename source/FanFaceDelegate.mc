import Toybox.Lang;
import Toybox.WatchUi;

// Phase 5: tap a rail cell to open the native glance (HR / Body Battery / Steps).
// WatchFaceDelegate.onPress (API 4.2.0) is the only touch hook a watch face gets outside
// config mode; Garmin documents it as "touch and hold".
class FanFaceDelegate extends WatchUi.WatchFaceDelegate {
    private var _view as FanFaceView;

    function initialize(view as FanFaceView) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    function onPress(clickEvent as WatchUi.ClickEvent) as Lang.Boolean {
        var c = clickEvent.getCoordinates();
        return _view.onFaceTap(c[0], c[1]);
    }
}

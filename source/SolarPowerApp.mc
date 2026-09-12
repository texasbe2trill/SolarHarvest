import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class SolarPowerApp extends Application.AppBase {

    private var _view as SolarPowerView?;

    function initialize() {
        AppBase.initialize();
        _view = null;
    }

    function onStart(state as Dictionary?) as Void {
    }

    function onStop(state as Dictionary?) as Void {
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        _view = new SolarPowerView();
        return [ _view ];
    }

    function onSettingsChanged() as Void {
        var view = _view;
        if (view != null) {
            view.loadSettings();
            WatchUi.requestUpdate();
        }
    }

}

function getApp() as SolarPowerApp {
    return Application.getApp() as SolarPowerApp;
}
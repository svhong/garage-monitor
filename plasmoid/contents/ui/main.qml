import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import "logic.js" as Logic

PlasmoidItem {
    id: root

    // ---- settings ----
    readonly property string hubUrl: Plasmoid.configuration.hubUrl
    readonly property string password: Plasmoid.configuration.password
    readonly property int pollSeconds: Math.max(1, Plasmoid.configuration.pollSeconds)
    readonly property string machineFilter: Plasmoid.configuration.machineFilter
    readonly property bool showSparklines: Plasmoid.configuration.showSparklines

    // ---- state ----
    property var views: []            // one formatted view per machine (see logic.js)
    property string errorText: ""
    property bool loaded: false       // at least one good response since start
    property string sessionToken: ""  // kept in memory only; re-login on restart
    property string badPassword: ""   // password the hub rejected; don't retry it
    property int requestId: 0
    property bool busy: false

    readonly property int worst: errorText ? Logic.BAD : Logic.worstLevel(views)
    readonly property bool onDesktop: Plasmoid.formFactor === PlasmaCore.Types.Planar
                                      || Plasmoid.formFactor === PlasmaCore.Types.MediaCenter

    preferredRepresentation: onDesktop ? fullRepresentation : compactRepresentation
    Plasmoid.backgroundHints: PlasmaCore.Types.DefaultBackground | PlasmaCore.Types.ConfigurableBackground
    Plasmoid.icon: "utilities-system-monitor"
    toolTipMainText: i18n("Garage Monitor")
    toolTipSubText: errorText ? errorText : Logic.summary(views)

    onHubUrlChanged: restart()
    onPasswordChanged: { badPassword = ""; restart(); }
    onMachineFilterChanged: restart()

    function restart() {
        sessionToken = "";
        errorText = "";
        busy = false;
        requestId++;      // drop any reply still on its way
        poll();
    }

    // ---- talking to the hub ----
    // One request at a time. Each gets an id so a late or timed-out reply is ignored.
    function send(method, path, body, onDone) {
        var id = ++requestId;
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE || id !== requestId) return;
            timeout.stop();
            var data = null;
            try { data = JSON.parse(xhr.responseText); } catch (e) { }
            onDone(xhr.status, data);
        };
        xhr.open(method, Logic.joinUrl(hubUrl, path));
        xhr.setRequestHeader("Content-Type", "application/json");
        if (sessionToken) xhr.setRequestHeader("Authorization", "Bearer " + sessionToken);
        timeout.xhr = xhr;
        timeout.restart();
        xhr.send(body ? JSON.stringify(body) : null);
    }

    function fail(text) {
        busy = false;
        errorText = text;
    }

    function poll() {
        if (busy) return;
        if (!hubUrl.trim()) return fail(i18n("Set the hub address in the widget settings."));
        busy = true;
        send("GET", "/api/machines", null, function (status, data) {
            if (status === 200 && data && data.machines) {
                busy = false;
                errorText = "";
                loaded = true;
                views = Logic.filterMachines(data.machines, machineFilter).map(Logic.view);
            } else if (status === 401) {
                login();
            } else if (status === 0) {
                fail(i18n("Can't reach the hub at %1", hubUrl));
            } else {
                fail(i18n("Hub answered %1", status));
            }
        });
    }

    function login() {
        sessionToken = "";
        if (!password) return fail(i18n("The hub needs a password. Add it in the widget settings."));
        if (password === badPassword) return fail(i18n("Wrong password. Fix it in the widget settings."));
        send("POST", "/api/login", { password: password }, function (status, data) {
            busy = false;
            if (status === 200 && data && data.token) {
                sessionToken = data.token;
                poll();
            } else if (status === 401 && data && /Too many/.test(data.error || "")) {
                fail(data.error);  // hub lockout; next poll tries again
            } else if (status === 401) {
                badPassword = password;
                fail(i18n("Wrong password. Fix it in the widget settings."));
            } else {
                fail(status === 0 ? i18n("Can't reach the hub at %1", hubUrl) : i18n("Login failed (%1)", status));
            }
        });
    }

    Timer {
        id: timeout
        property var xhr: null
        interval: 5000
        onTriggered: {
            root.requestId++;
            if (xhr) xhr.abort();
            root.fail(i18n("The hub at %1 isn't answering", root.hubUrl));
        }
    }

    Timer {
        interval: root.pollSeconds * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }

    // ---- what you see ----
    compactRepresentation: MouseArea {
        hoverEnabled: true
        onClicked: root.expanded = !root.expanded

        Kirigami.Icon {
            anchors.fill: parent
            source: Plasmoid.icon
            active: parent.containsMouse
        }
        StatusDot {
            anchors { right: parent.right; bottom: parent.bottom }
            size: Math.max(6, Math.round(parent.height / 3.5))
            level: root.worst
            outlined: true
        }
    }

    fullRepresentation: FullView {
        views: root.views
        errorText: root.errorText
        loaded: root.loaded
        showSparklines: root.showSparklines
        onDesktop: root.onDesktop
    }
}

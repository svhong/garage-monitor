import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_hubUrl: hubUrl.text
    property alias cfg_password: password.text
    property alias cfg_pollSeconds: poll.value
    property alias cfg_machineFilter: machineFilter.text
    property alias cfg_showSparklines: sparklines.checked

    // Plasma also passes each setting's default; declaring them keeps the log quiet.
    property string cfg_hubUrlDefault
    property string cfg_passwordDefault
    property int cfg_pollSecondsDefault
    property string cfg_machineFilterDefault
    property bool cfg_showSparklinesDefault

    Kirigami.FormLayout {
        QQC2.TextField {
            id: hubUrl
            Kirigami.FormData.label: i18n("Hub address:")
            placeholderText: "http://hermes-box:8787"
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        }
        QQC2.Label {
            text: i18n("Your hub's Tailscale name or IP, with port 8787.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        Kirigami.PasswordField {
            id: password
            Kirigami.FormData.label: i18n("Viewer password:")
            placeholderText: i18n("Leave blank if the hub has none")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        }
        QQC2.Label {
            text: i18n("Saved unencrypted in your Plasma settings file, readable by your user account.")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
            wrapMode: Text.WordWrap
            Layout.maximumWidth: Kirigami.Units.gridUnit * 20
        }

        Item { Kirigami.FormData.isSection: true }

        QQC2.SpinBox {
            id: poll
            Kirigami.FormData.label: i18n("Update every:")
            from: 1
            to: 60
            textFromValue: function (value) { return i18np("%1 second", "%1 seconds", value); }
            valueFromText: function (text) { return parseInt(text) || 2; }
        }

        QQC2.TextField {
            id: machineFilter
            Kirigami.FormData.label: i18n("Machines:")
            placeholderText: i18n("All machines")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 16
        }
        QQC2.Label {
            text: i18n("Comma-separated names, in the order you want them, e.g. hermes-box, nas")
            font: Kirigami.Theme.smallFont
            opacity: 0.7
        }

        QQC2.CheckBox {
            id: sparklines
            Kirigami.FormData.label: i18n("Graph:")
            text: i18n("Show the last 5 minutes of CPU load and temperature")
        }
    }
}

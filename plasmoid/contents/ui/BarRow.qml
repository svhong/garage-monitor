import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "logic.js" as Logic

RowLayout {
    id: row
    property string label
    property var pct: null
    property int level: Logic.OK
    property string text
    property string sub: ""
    property int subLevel: Logic.OK
    property bool dimmed: false

    spacing: Kirigami.Units.smallSpacing * 2

    PlasmaComponents.Label {
        text: row.label
        opacity: 0.7
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.6
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.round(Kirigami.Units.gridUnit * 0.4)
        radius: height / 2
        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)

        Rectangle {
            readonly property real p: (typeof row.pct === "number" && isFinite(row.pct)) ? Math.max(0, Math.min(100, row.pct)) : 0
            width: parent.width * p / 100
            height: parent.height
            radius: parent.radius
            color: row.dimmed ? Kirigami.Theme.disabledTextColor
                 : row.level === Logic.OK ? Kirigami.Theme.highlightColor
                 : Logic.levelColor(Kirigami.Theme, row.level)
            Behavior on width { NumberAnimation { duration: Kirigami.Units.longDuration } }
        }
    }

    PlasmaComponents.Label {
        text: row.text
        font: Kirigami.Theme.smallFont
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
    }

    PlasmaComponents.Label {
        text: row.sub
        visible: text.length > 0
        font: Kirigami.Theme.smallFont
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2
        color: row.subLevel === Logic.OK || row.dimmed ? Kirigami.Theme.textColor
                                                       : Logic.levelColor(Kirigami.Theme, row.subLevel)
        opacity: row.subLevel === Logic.OK ? 0.7 : 1
    }
}

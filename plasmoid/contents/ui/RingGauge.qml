import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "logic.js" as Logic

// A 270° ring with the value in the middle and a caption underneath.
ColumnLayout {
    id: gauge
    property string label
    property var value: null
    property real min: 0
    property real max: 100
    property int level: Logic.OK
    property string text: "–"
    property string sub: ""
    property bool dimmed: false
    property real diameter: Kirigami.Units.gridUnit * 4.2

    spacing: Kirigami.Units.smallSpacing / 2

    readonly property real fraction: (typeof value === "number" && isFinite(value))
                                     ? Math.max(0, Math.min(1, (value - min) / (max - min))) : 0
    readonly property color arcColor: dimmed ? Kirigami.Theme.disabledTextColor
                                     : level === Logic.OK ? Kirigami.Theme.highlightColor
                                     : Logic.levelColor(Kirigami.Theme, level)

    onFractionChanged: canvas.requestPaint()
    onArcColorChanged: canvas.requestPaint()

    Item {
        Layout.alignment: Qt.AlignHCenter
        implicitWidth: gauge.diameter
        implicitHeight: gauge.diameter

        Canvas {
            id: canvas
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var line = Math.max(3, width * 0.085);
                var r = (Math.min(width, height) - line) / 2;
                var cx = width / 2, cy = height / 2;
                var start = Math.PI * 0.75, sweep = Math.PI * 1.5;
                ctx.lineCap = "round";
                ctx.lineWidth = line;
                ctx.strokeStyle = Logic.css(Kirigami.Theme.textColor, 0.12);
                ctx.beginPath();
                ctx.arc(cx, cy, r, start, start + sweep, false);
                ctx.stroke();
                if (gauge.fraction > 0.005) {
                    ctx.strokeStyle = Logic.css(gauge.arcColor, 1);
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, start, start + sweep * gauge.fraction, false);
                    ctx.stroke();
                }
            }
        }

        PlasmaComponents.Label {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -Kirigami.Units.smallSpacing / 2
            text: gauge.text
            font.pixelSize: gauge.diameter * 0.24
            font.weight: Font.DemiBold
            color: gauge.level === Logic.OK || gauge.dimmed ? Kirigami.Theme.textColor
                                                           : Logic.levelColor(Kirigami.Theme, gauge.level)
        }
        PlasmaComponents.Label {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: gauge.diameter * 0.04
            text: gauge.label
            font.pixelSize: gauge.diameter * 0.13
            opacity: 0.7
        }
    }

    PlasmaComponents.Label {
        Layout.alignment: Qt.AlignHCenter
        Layout.maximumWidth: gauge.diameter * 1.25
        text: gauge.sub || " "   // keep the line so all gauges in a row line up
        elide: Text.ElideRight
        font: Kirigami.Theme.smallFont
        opacity: 0.7
    }
}

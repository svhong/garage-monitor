import QtQuick
import org.kde.kirigami as Kirigami
import "logic.js" as Logic

Rectangle {
    property int level: Logic.UNKNOWN
    property real size: Kirigami.Units.gridUnit * 0.55
    property bool outlined: false

    width: size
    height: size
    radius: size / 2
    color: Logic.levelColor(Kirigami.Theme, level)
    border.width: outlined ? Math.max(1, size / 6) : 0
    border.color: Kirigami.Theme.backgroundColor
}

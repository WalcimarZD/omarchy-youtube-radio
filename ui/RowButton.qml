import QtQuick
import qs.Commons

// Botao pequeno de linha (acoes inline: subir, descer, remover, renomear).
// Fundo, hover e tooltip seguem o kit do Omarchy.
Item {
  id: root

  property string text: ""
  property string tooltipText: ""
  property var bar: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool enabled: true
  property int minimumWidth: Style.space(20)

  signal clicked()

  implicitWidth: Math.max(root.minimumWidth, label.implicitWidth + Style.space(10))
  implicitHeight: Math.max(Style.space(20), label.implicitHeight + Style.space(4))
  opacity: root.enabled ? 1 : 0.35

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: hover.hovered && root.enabled
      ? Style.hoverFillFor(root.foreground, root.accent)
      : "transparent"

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: true
      enabled: root.enabled
      cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.clicked()
      onEntered: if (root.bar && root.tooltipText !== "") root.bar.showTooltip(root, root.tooltipText)
      onExited: if (root.bar) root.bar.hideTooltip(root)
    }
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    textFormat: Text.PlainText
    color: hover.hovered && root.enabled ? root.accent : root.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    renderType: Text.NativeRendering
  }
}

import QtQuick
import qs.Commons

// Aba "Tocando": fila atual (origem: playlist, URL avulsa ou busca), com o item
// em reproducao destacado e acoes de reordenar/remover quando a fila veio de
// uma playlist (so nesse caso o indice da fila == indice na playlist).
Column {
  id: root

  property var svc: null
  property var bar: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property int cursor: -1
  property bool showActions: true

  signal activated(int index)
  signal removed(int index)
  signal moved(int index, int delta)
  signal saveRequested()
  signal reloadRequested()

  spacing: Style.space(2)
  width: parent ? parent.width : implicitWidth

  readonly property bool editable: root.svc !== null && root.svc.currentPlaylistId !== ""
  readonly property var items: root.svc ? root.svc.queue : []

  Text {
    visible: root.items.length === 0
    width: parent.width
    text: "Fila vazia. Cole uma URL, busque um termo ou escolha uma playlist."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.foreground, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: root.items
    delegate: Item {
      id: row
      required property int index
      required property var modelData

      width: root.width
      height: Style.space(26)
      readonly property bool current: root.svc !== null && root.svc.currentIndex === row.index
      readonly property bool selected: root.cursor === row.index

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.current
          ? Style.selectedFillFor(root.foreground, root.accent)
          : (row.selected ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.activated(row.index)
        }
      }

      Text {
        id: marker
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: row.current ? "" : (row.modelData.playable === false ? "" : "")
        color: root.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        id: label
        anchors.left: marker.right
        anchors.leftMargin: Style.space(4)
        anchors.right: actions.visible ? actions.left : parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: (row.index + 1) + ". " + String(row.modelData.label)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: row.modelData.playable === false
          ? Qt.darker(root.foreground, 1.7)
          : (row.current ? root.accent : root.foreground)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        id: actions
        visible: root.showActions && root.editable
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        RowButton {
          text: "\uf062"
          tooltipText: "Subir"
          bar: root.bar
          foreground: root.foreground
          accent: root.accent
          enabled: row.index > 0
          onClicked: root.moved(row.index, -1)
        }
        RowButton {
          text: "\uf063"
          tooltipText: "Descer"
          bar: root.bar
          foreground: root.foreground
          accent: root.accent
          enabled: row.index < root.items.length - 1
          onClicked: root.moved(row.index, 1)
        }
        RowButton {
          text: "\uf00d"
          tooltipText: "Remover da playlist"
          bar: root.bar
          foreground: root.foreground
          accent: root.urgent
          onClicked: root.removed(row.index)
        }
      }
    }
  }

  Row {
    visible: root.showActions && root.items.length > 0
    spacing: Style.space(4)

    RowButton {
      text: "Salvar faixa atual"
      tooltipText: "Adiciona o item em reproducao a uma playlist"
      bar: root.bar
      foreground: root.foreground
      accent: root.accent
      onClicked: root.saveRequested()
    }
    RowButton {
      text: "Reaplicar fila"
      tooltipText: "Recarrega a fila a partir da playlist salva"
      bar: root.bar
      foreground: root.foreground
      accent: root.accent
      enabled: root.svc !== null && root.svc.hasQueue
      onClicked: root.reloadRequested()
    }
  }
}

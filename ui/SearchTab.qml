import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Aba "Buscar": campo unico que aceita URL do YouTube (toca direto) ou termo de
// busca (lista resultados do yt-dlp para escolher).
Column {
  id: root

  property var svc: null
  property var bar: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property int cursor: 0
  property alias fieldItem: field

  signal submitted(string text)
  signal picked(int index)

  readonly property bool inputActive: field.activeFocus
  readonly property var results: root.svc ? root.svc.searchResults : []
  readonly property bool busy: root.svc ? root.svc.searchBusy : false

  spacing: Style.space(4)
  width: parent ? parent.width : implicitWidth

  Row {
    width: parent.width
    spacing: Style.space(4)

    TextField {
      id: field
      width: parent.width - submit.width - Style.space(4)
      placeholderText: "Cole uma URL do YouTube ou digite a busca e Enter"
      foreground: root.foreground
      accent: root.accent
      onAccepted: root.submitted(text)

      Keys.onEscapePressed: function(event) {
        field.focus = false
        event.accepted = true
      }
    }

    RowButton {
      id: submit
      text: "Buscar"
      tooltipText: "URL toca direto; termo abre a busca"
      bar: root.bar
      foreground: root.foreground
      accent: root.accent
      implicitHeight: field.height
      onClicked: root.submitted(field.text)
    }
  }

  Text {
    width: parent.width
    visible: root.busy || (root.svc !== null && root.svc.searchError !== "")
    text: root.busy ? "Buscando…" : String(root.svc ? root.svc.searchError : "")
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.busy ? Qt.darker(root.foreground, 1.5) : root.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: root.results
    delegate: Item {
      id: row
      required property int index
      required property var modelData

      width: root.width
      height: Style.space(26)
      readonly property bool selected: root.cursor === row.index

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.selected ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.picked(row.index)
        }
      }

      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.right: duration.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: (row.index + 1) + ". " + String(row.modelData.title)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: row.selected ? root.accent : root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        id: duration
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        text: Model.formatTime(row.modelData.duration)
        color: Qt.darker(root.foreground, 1.5)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  Text {
    width: parent.width
    visible: !root.busy && root.results.length > 0
    text: "Enter/1-9 toca o resultado selecionado · ↑↓ navega"
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.6)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
}

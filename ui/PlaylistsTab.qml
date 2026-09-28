import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Aba "Playlists": criar, tocar, renomear, apagar e editar itens de listas
// locais. O conteudo vive em playlists.json (via Service); aqui e so a UI.
Column {
  id: root

  property var svc: null
  property var bar: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property int cursor: 0
  property alias createFieldItem: createField

  signal playRequested(string id)
  signal createRequested(string name)
  signal renameRequested(string id, string name)
  signal deleteRequested(string id)
  signal itemRemoved(string id, int index)
  signal itemMoved(string id, int index, int delta)
  signal addCurrentRequested(string id)

  property string expandedId: ""
  property string renamingId: ""
  property string confirmingId: ""
  // Ids dentro de um Repeater sao escopados ao delegate, entao o foco do campo
  // de renomear sobe para o root por propriedade.
  property bool renameActive: false

  readonly property var items: root.svc ? root.svc.playlists : []
  readonly property bool inputActive: createField.activeFocus || root.renameActive
  readonly property string selectedId: root.selectedPlaylistId()

  function selectedPlaylistId() {
    if (root.items.length === 0) return ""
    var index = Math.max(0, Math.min(root.cursor, root.items.length - 1))
    return String(root.items[index].id)
  }

  // Chamado pelo teclado (x): primeiro pede confirmacao, depois apaga.
  function requestDeleteSelected() {
    var id = root.selectedId
    if (id === "") return
    if (root.confirmingId === id) {
      root.confirmingId = ""
      root.deleteRequested(id)
      return
    }
    root.confirmingId = id
  }

  function startRenameSelected() {
    var id = root.selectedId
    if (id === "") return
    root.renamingId = id
  }

  function playlistName(id) {
    for (var i = 0; i < root.items.length; i++) {
      if (String(root.items[i].id) === String(id)) return String(root.items[i].name)
    }
    return ""
  }

  function playlistMode(id) {
    for (var i = 0; i < root.items.length; i++) {
      if (String(root.items[i].id) === String(id)) return Model.modeLabel(root.items[i].mode)
    }
    return ""
  }

  spacing: Style.space(4)
  width: parent ? parent.width : implicitWidth

  Row {
    width: parent.width
    spacing: Style.space(4)

    TextField {
      id: createField
      width: parent.width - createButton.width - Style.space(4)
      placeholderText: "Nome da nova playlist"
      foreground: root.foreground
      accent: root.accent
      onAccepted: root.submitCreate()

      Keys.onEscapePressed: function(event) {
        createField.focus = false
        event.accepted = true
      }
    }

    RowButton {
      id: createButton
      text: "Criar"
      tooltipText: "Cria uma playlist vazia"
      bar: root.bar
      foreground: root.foreground
      accent: root.accent
      implicitHeight: createField.height
      onClicked: root.submitCreate()
    }
  }

  function submitCreate() {
    var name = String(createField.text).trim()
    if (name === "") return
    root.createRequested(name)
    createField.text = ""
    createField.focus = false
  }

  Text {
    width: parent.width
    visible: root.items.length === 0
    text: "Nenhuma playlist ainda. Crie uma acima ou salve a faixa atual."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.foreground, 1.5)
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  Repeater {
    model: root.items
    delegate: Column {
      id: playlistRow
      required property int index
      required property var modelData

      readonly property bool selected: root.cursor === playlistRow.index
      readonly property bool expanded: String(modelData.id) === root.expandedId
      readonly property bool playing: root.svc !== null
        && String(root.svc.currentPlaylistId) === String(modelData.id)

      width: root.width
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: Style.space(26)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: playlistRow.playing
            ? Style.selectedFillFor(root.foreground, root.accent)
            : (playlistRow.selected ? Style.hoverFillFor(root.foreground, root.accent) : "transparent")

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.playRequested(String(playlistRow.modelData.id))
          }
        }

        Text {
          id: playlistLabel
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.right: playlistActions.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          text: String(playlistRow.modelData.name)
            + "  ·  " + Number(playlistRow.modelData.count) + " item(ns)"
            + "  ·  " + Model.modeLabel(playlistRow.modelData.mode)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: playlistRow.playing ? root.accent : root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          id: playlistActions
          anchors.right: parent.right
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          RowButton {
            text: playlistRow.expanded ? "\uf0d7" : "\uf0da"
            tooltipText: playlistRow.expanded ? "Recolher itens" : "Editar itens"
            bar: root.bar
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              root.confirmingId = ""
              root.expandedId = playlistRow.expanded ? "" : String(playlistRow.modelData.id)
            }
          }
          RowButton {
            text: "\uf044"
            tooltipText: "Renomear"
            bar: root.bar
            foreground: root.foreground
            accent: root.accent
            onClicked: {
              root.confirmingId = ""
              root.renamingId = String(playlistRow.modelData.id)
            }
          }
          RowButton {
            text: root.confirmingId === String(playlistRow.modelData.id) ? "\uf00c" : "\uf1f8"
            tooltipText: root.confirmingId === String(playlistRow.modelData.id)
              ? "Clique de novo para apagar" : "Apagar playlist"
            bar: root.bar
            foreground: root.foreground
            accent: root.urgent
            onClicked: {
              if (root.confirmingId === String(playlistRow.modelData.id)) {
                root.confirmingId = ""
                root.deleteRequested(String(playlistRow.modelData.id))
                return
              }
              root.confirmingId = String(playlistRow.modelData.id)
            }
          }
        }
      }

      TextField {
        id: renameField
        visible: root.renamingId === String(playlistRow.modelData.id)
        width: parent.width
        foreground: root.foreground
        accent: root.accent
        placeholderText: "Novo nome"
        onVisibleChanged: {
          if (!visible) {
            root.renameActive = false
            return
          }
          text = String(playlistRow.modelData.name)
          Qt.callLater(function() { renameField.forceActiveFocus() })
        }
        onActiveFocusChanged: {
          if (root.renamingId === String(playlistRow.modelData.id)) root.renameActive = activeFocus
        }
        onAccepted: {
          var name = String(renameField.text).trim()
          if (name !== "") root.renameRequested(String(playlistRow.modelData.id), name)
          root.renamingId = ""
          root.renameActive = false
          renameField.focus = false
        }

        Keys.onEscapePressed: function(event) {
          root.renamingId = ""
          root.renameActive = false
          renameField.focus = false
          event.accepted = true
        }
      }

      Row {
        visible: playlistRow.expanded
        spacing: Style.space(4)

        RowButton {
          text: "Salvar faixa atual aqui"
          tooltipText: "Adiciona o item em reproducao ao fim desta playlist"
          bar: root.bar
          foreground: root.foreground
          accent: root.accent
          onClicked: root.addCurrentRequested(String(playlistRow.modelData.id))
        }
        RowButton {
          text: "Tocar"
          bar: root.bar
          foreground: root.foreground
          accent: root.accent
          onClicked: root.playRequested(String(playlistRow.modelData.id))
        }
      }

      Column {
        visible: playlistRow.expanded
        width: parent.width
        spacing: Style.space(1)

        Repeater {
          model: playlistRow.expanded ? (playlistRow.modelData.items || []) : []
          delegate: Item {
            id: itemRow
            required property int index
            required property var modelData

            width: playlistRow.width
            height: Style.space(24)

            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.right: itemActions.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: (itemRow.index + 1) + ". " + String(itemRow.modelData.value)
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: Qt.darker(root.foreground, 1.2)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              id: itemActions
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
                enabled: itemRow.index > 0
                onClicked: root.itemMoved(String(playlistRow.modelData.id), itemRow.index, -1)
              }
              RowButton {
                text: "\uf063"
                tooltipText: "Descer"
                bar: root.bar
                foreground: root.foreground
                accent: root.accent
                enabled: itemRow.index < (playlistRow.modelData.items || []).length - 1
                onClicked: root.itemMoved(String(playlistRow.modelData.id), itemRow.index, 1)
              }
              RowButton {
                text: "\uf00d"
                tooltipText: "Remover item"
                bar: root.bar
                foreground: root.foreground
                accent: root.urgent
                onClicked: root.itemRemoved(String(playlistRow.modelData.id), itemRow.index)
              }
            }
          }
        }
      }
    }
  }
}

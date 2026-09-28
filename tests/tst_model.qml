import QtQuick
import "../Model.js" as Model

// Harness headless das assercoes de Model.js:
//   QT_QPA_PLATFORM=offscreen qml6 tests/tst_model.qml 2>/dev/null | grep MODEL_SELFTEST
// Imprime "MODEL_SELFTEST_OK" quando tudo passa, ou "MODEL_SELFTEST_FAIL: ...".
Item {
  id: root
  width: 1
  height: 1

  Component.onCompleted: {
    var failures = Model.selfTest()
    if (failures !== "") console.log(failures)
    Qt.exit(failures === "" ? 0 : 1)
  }
}

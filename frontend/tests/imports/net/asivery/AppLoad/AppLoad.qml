import QtQuick 2.5

QtObject {
    objectName: "testAppLoadEndpoint"
    property string applicationID
    property var sentMessages: []
    signal messageReceived(int type, string contents)

    function sendMessage(type, contents) {
        sentMessages.push(JSON.parse(contents))
    }

    function reply(message) {
        messageReceived(1, JSON.stringify(message))
    }
}

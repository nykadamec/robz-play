import QtCore
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Dialogs

import org.streetpea.chiaking

import "controls" as C

DialogView {
    enum Console {
        PS4,
        PS5
    }
    property int selectedConsole: SettingsDialog.Console.PS5
    property bool quitControllerMapping: true
    // the section shown first: 0 General, 1 Video, 2 Stream, ... in the order of the list
    property int startSection: 0
    Component.onCompleted: {
        if (startSection > 0)
            bar.currentIndex = startSection;
    }
    // leaving the settings: offer the restart that a changed setting is waiting for
    StackView.onRemoved: {
        if (root.restartPending)
            Qt.callLater(root.askRestart);
    }
    id: dialog
    title: qsTr("Settings")
    header: qsTr("Values in brackets are the defaults")
    buttonVisible: false
    function flickContainsItem(flick, item) {
        let current = item;
        while (current) {
            if (current === flick || current === flick.contentItem)
                return true;
            current = current.parent;
        }
        return false;
    }
    function flickVisibilityTarget(flick, item) {
        let current = item;
        while (current && current !== flick && current !== flick.contentItem) {
            if (current.parent === flick.contentItem)
                return current;
            if (current.parent && current.parent.parent === flick.contentItem)
                return current;
            current = current.parent;
        }
        return item;
    }
    function ensureItemVisibleInFlick(flick, item) {
        if (!flick || !item || !flickContainsItem(flick, item))
            return;
        const air = 28;
        // A control on the first screenful: stay at the top, so the section heading shows too.
        if (item.mapToItem(flick.contentItem, 0, 0).y + item.height + air <= flick.height) {
            flick.contentY = 0;
            return;
        }
        let target = flickVisibilityTarget(flick, item);
        // A block taller than the view cannot be shown whole: follow the control itself.
        if (target.height > flick.height)
            target = item;
        const top = target.mapToItem(flick.contentItem, 0, 0).y;
        const bottom = top + target.height;
        if (top - air < flick.contentY)
            flick.contentY = Math.max(0, top - air);
        else if (bottom + air > flick.contentY + flick.height)
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), bottom + air - flick.height);
    }
    function itemIsInsideNestedScrollable(flick, item) {
        let current = item ? item.parent : null;
        while (current && current !== flick && current !== flick.contentItem) {
            if (current.contentY !== undefined && current.contentHeight !== undefined && current !== flick)
                return true;
            current = current.parent;
        }
        return false;
    }
    function nestedScrollableTarget(flick, item) {
        let current = item;
        while (current && current !== flick && current !== flick.contentItem) {
            if (current.contentY !== undefined && current.contentHeight !== undefined && current !== flick)
                return current;
            current = current.parent;
        }
        return item;
    }
    function ensureActiveFocusVisible() {
        const flick = activeSettingsFlick();
        const window = dialog.Window.window;
        if (!flick || !window || !window.activeFocusItem)
            return;
        const target = itemIsInsideNestedScrollable(flick, window.activeFocusItem)
            ? nestedScrollableTarget(flick, window.activeFocusItem)
            : window.activeFocusItem;
        ensureItemVisibleInFlick(flick, target);
    }
    function scrollFlickKeepingItemVisible(flick, item, delta) {
        if (!flick || !item)
            return;
        const maxContentY = Math.max(0, flick.contentHeight - flick.height);
        if (maxContentY <= 0)
            return;
        flick.contentY = Math.max(0, Math.min(maxContentY, flick.contentY + delta));
    }
    function focusCurrentTabFirstItem() {
        let item = null;
        switch (bar.currentIndex) {
        case 0: item = disconnectAction; break;
        case 1: item = hwDecoderCombo; break;
        case 2: item = consoleSelection; break;
        case 3: item = audioOutDevice; break;
        case 4: item = registerNewButton; break;
        case 5: item = resetAllKeys; break;
        case 6: item = controllerMappingChange; break;
        case 7: item = firstRemoteFocusableItem(); break;
        case 8: item = profile; break;
        case 9: item = logOpenFolderButton; break;
        }
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }
    function activeSettingsFlick() {
        switch (bar.currentIndex) {
        case 0: return generalFlick;
        case 1: return videoFlick;
        case 2: return streamFlick;
        case 3: return audiowifiFlick;
        case 4: return consolesFlick;
        case 5: return keysFlick;
        case 6: return controllersFlick;
        case 7: return remoteFlick;
        case 8: return configFlick;
        case 9: return logFlick;
        default: return null;
        }
    }

    function firstRemoteFocusableItem() {
        if (openPsnLogin.visible)
            return openPsnLogin;
        if (resetPsnTokens.visible)
            return resetPsnTokens;
        if (holePunchGuessingCheckbox.visible)
            return holePunchGuessingCheckbox;
        if (portGuessCountSlider.visible)
            return portGuessCountSlider;
        if (portGuessSocketSlider.visible)
            return portGuessSocketSlider;
        return remoteFlick;
    }
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            bar.decrementCurrentIndex();
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            bar.incrementCurrentIndex();
            event.accepted = true;
            break;
        case Qt.Key_Up:
        {
            const flick = activeSettingsFlick();
            if (!flick || flick.contentHeight <= flick.height || flick.contentY <= 0.001)
                return;
            flick.flick(0, 500);
            event.accepted = true;
            break;
        }
        case Qt.Key_Down:
        {
            const flick = activeSettingsFlick();
            if (!flick || flick.contentHeight <= flick.height || flick.contentY >= flick.contentHeight - flick.height - 0.001)
                return;
            flick.flick(0, -500);
            event.accepted = true;
            break;
        }
        }
    }

    Item {
        // The tab bar is kept as the holder of the current section (every key handler and
        // focus rule in this file refers to bar.currentIndex) but is no longer shown: the
        // column on the left does the navigating.
        TabBar {
            id: bar
            visible: false
            height: 0
            anchors {
                top: parent.top
                left: parent.left
                right: parent.right
            }
            TabButton {
                id: general
                text: qsTr("General")
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        left: general.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 1
                }
            }

            TabButton {
                id: video
                text: qsTr("Video")
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: video.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 0
                }
                Image {
                    anchors {
                        left: video.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 2
                }
            }

            TabButton {
                id: stream
                text: qsTr("Stream")
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: stream.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 1
                }
                Image {
                    anchors {
                        left: stream.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 3
                }
            }

            TabButton {
                text: qsTr("Audio/Wifi")
                id: audio
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: audio.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 2
                }
                Image {
                    anchors {
                        left: audio.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 4
                }
            }

            TabButton {
                text: qsTr("Consoles")
                id: consoles
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: consoles.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 3
                }
                Image {
                    anchors {
                        left: consoles.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 5
                }
            }

            TabButton {
                text: qsTr("Keys")
                id: keys
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: keys.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 4
                }
                Image {
                    anchors {
                        left: keys.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 6
                }
            }

            TabButton {
                text: qsTr("Controllers")
                id: controllers
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: controllers.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 5
                }
                Image {
                    anchors {
                        left: controllers.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 7
                }
            }

            TabButton {
                text: qsTr("Remote")
                id: remote
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        right: remote.left
                        verticalCenter: parent.verticalCenter
                        rightMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 6
                }
                Image {
                    anchors {
                        left: remote.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                    visible: bar.currentIndex == 8
                }
            }

            TabButton {
                text: qsTr("Config")
                id: config
                focusPolicy: Qt.NoFocus
                Image {
                    anchors {
                        left: config.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: -15
                    }
                    width: 28
                    height: 28
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                    visible: bar.currentIndex == 7
                }
            }

            TabButton {
                id: logsTab
                text: qsTr("Logs")
                focusPolicy: Qt.NoFocus
            }
        }

        Rectangle {
            id: settingsNav
            anchors {
                top: parent.top
                left: parent.left
                bottom: parent.bottom
            }
            width: 300
            color: "#100D0C"

            Rectangle {
                anchors.right: parent.right
                width: 1
                height: parent.height
                color: "#3B302B"
            }

            Column {
                anchors {
                    top: parent.top
                    left: parent.left
                    right: parent.right
                    margins: 18
                    topMargin: 22
                }
                spacing: 4

                Repeater {
                    model: [
                        { title: qsTr("General"), note: qsTr("Frame generation and basics") },
                        { title: qsTr("Video"), note: qsTr("Decoder, window, renderer") },
                        { title: qsTr("Stream"), note: qsTr("Resolution, frame rate, bitrate") },
                        { title: qsTr("Audio and network"), note: qsTr("Sound devices and volume") },
                        { title: qsTr("Consoles"), note: qsTr("Registered and hidden consoles") },
                        { title: qsTr("Keyboard"), note: qsTr("Keys for controller buttons") },
                        { title: qsTr("Controllers"), note: qsTr("Button mapping") },
                        { title: qsTr("Remote play"), note: qsTr("PSN sign-in") },
                        { title: qsTr("Profiles and data"), note: qsTr("Profiles, import, export, logs") },
                        { title: qsTr("Logs"), note: qsTr("What happened, for support") }
                    ]

                    AbstractButton {
                        id: navEntry
                        required property int index
                        required property var modelData
                        readonly property bool current: bar.currentIndex === index
                        width: parent.width
                        height: 54
                        focusPolicy: Qt.NoFocus
                        hoverEnabled: true
                        onClicked: bar.currentIndex = index
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        background: Rectangle {
                            radius: 10
                            color: navEntry.current ? "#1D1816" : (navEntry.hovered ? "#1B1615" : "transparent")
                            border.width: navEntry.current ? 1 : 0
                            border.color: "#3B302B"
                            Rectangle {
                                visible: navEntry.current
                                anchors {
                                    left: parent.left
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 6
                                }
                                width: 3
                                height: 26
                                radius: 2
                                color: "#E4845E"
                            }
                        }
                        contentItem: Column {
                            leftPadding: 20
                            topPadding: 7
                            spacing: 1
                            Label {
                                text: navEntry.modelData.title
                                color: navEntry.current ? "#FBF4EC" : "#CDBFB4"
                                font.pixelSize: 17
                                font.weight: navEntry.current ? Font.DemiBold : Font.Normal
                            }
                            Label {
                                text: navEntry.modelData.note
                                color: "#A08F84"
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }

            // controller and keyboard hint: the shoulder buttons / Page Up, Page Down switch section
            Row {
                anchors {
                    left: parent.left
                    bottom: parent.bottom
                    leftMargin: 26
                    bottomMargin: 22
                }
                spacing: 8
                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/l1.svg"
                }
                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24
                    sourceSize: Qt.size(width, height)
                    source: "qrc:/icons/r1.svg"
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Switch section")
                    color: "#A08F84"
                    font.pixelSize: 13
                }
            }
        }

        StackLayout {
            anchors {
                top: parent.top
                left: settingsNav.right
                right: parent.right
                bottom: parent.bottom
            }
            currentIndex: bar.currentIndex
            onCurrentIndexChanged: {
                dialog.focusCurrentTabFirstItem()
                Qt.callLater(dialog.ensureActiveFocusVisible)
            }

            Item {
                // General
                Flickable {
                    id: generalFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, generalLayout.width + 140)
                    contentHeight: generalLayout.y + generalLayout.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: generalFlick.contentHeight > generalFlick.height
                    }
                    Rectangle {
                        x: generalLayout.x - 32
                        y: generalLayout.y - 28
                        width: generalLayout.width + 64
                        height: generalLayout.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: generalLayout.x - 32
                        y: 14
                        text: qsTr("General")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: generalLayout.x - 32
                        y: 66
                        text: qsTr("Frame generation, what happens on disconnect, and other basics.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    ColumnLayout {
                        id: generalLayout
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        spacing: 10
                        GridLayout {
                            Layout.alignment: Qt.AlignHCenter
                            columns: 3
                            rowSpacing: 5
                            columnSpacing: 20

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Action On Disconnect:")
                            }

                        C.ComboBox {
                            id: disconnectAction
                            Layout.preferredWidth: 400
                            firstInFocusChain: true
                            model: [qsTr("Do Nothing"), qsTr("Enter Sleep Mode"), qsTr("Ask")]
                            currentIndex: Chiaki.settings.disconnectAction
                            onActivated: index => Chiaki.settings.disconnectAction = index
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Ask)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Frame Generation:")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.frameGenEnabled
                            onToggled: Chiaki.settings.frameGenEnabled = !Chiaki.settings.frameGenEnabled
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(On)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("FPS Counter During Gameplay:")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.showFpsCounter
                            onToggled: Chiaki.settings.showFpsCounter = !Chiaki.settings.showFpsCounter
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(On)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Check For Updates:")
                        }

                        C.CheckBox {
                            checked: Chiaki.updater.autoCheck
                            onToggled: Chiaki.updater.autoCheck = checked
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(On)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Frame Generation Motion Detail:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [
                                qsTr("Auto (Smart 60/120 FPS Lock)"),
                                qsTr("Fast (quarter resolution, 25%)"),
                                qsTr("Performance (third resolution, 33%)"),
                                qsTr("Balanced (half resolution, 50%)"),
                                qsTr("High (full resolution, 100%)")
                            ]
                            currentIndex: {
                                switch (Chiaki.settings.frameGenFlowDivisor) {
                                case 0: return 0;
                                case 4: return 1;
                                case 3: return 2;
                                case 2: return 3;
                                case 1: return 4;
                                default: return 0;
                                }
                            }
                            onActivated: index => Chiaki.settings.frameGenFlowDivisor = [0, 4, 3, 2, 1][index]
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Auto)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Smart GPU Auto-Scale (60 FPS Lock):")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.frameGenAutoScale
                            onToggled: Chiaki.settings.frameGenAutoScale = !Chiaki.settings.frameGenAutoScale
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            Layout.maximumWidth: 420
                            color: "#A08F84"
                            font.pixelSize: 14
                            wrapMode: Text.Wrap
                            text: qsTr("(On) Automatically lowers motion resolution if GPU exceeds frame time budget.")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Frame Generation Target:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [qsTr("60 FPS"), qsTr("120 FPS (Experimental)")]
                            currentIndex: Chiaki.settings.frameGenTargetFps === 120 ? 1 : 0
                            onActivated: index => Chiaki.settings.frameGenTargetFps = index === 1 ? 120 : 60
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(60 FPS)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Keep HUD And Text Steady:")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.frameGenProtectStatic
                            onToggled: Chiaki.settings.frameGenProtectStatic = !Chiaki.settings.frameGenProtectStatic
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(On)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("30 / 60 Comparison View:")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.frameGenCompare
                            onToggled: Chiaki.settings.frameGenCompare = !Chiaki.settings.frameGenCompare
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            Layout.maximumWidth: 420
                            color: "#A08F84"
                            font.pixelSize: 14
                            wrapMode: Text.Wrap
                            text: qsTr("(Off) Left half: the console's real frames only. Right half: with frame generation.")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Picture Sharpening:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [qsTr("Off"), qsTr("Low"), qsTr("Medium"), qsTr("High")]
                            currentIndex: Chiaki.settings.sharpening
                            onActivated: index => Chiaki.settings.sharpening = index
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(High)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Image Enhancement Technology:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [
                                qsTr("Off (Plain Stream)"),
                                qsTr("Robz Adaptive Luma Sharpen"),
                                qsTr("AMD FidelityFX CAS (Contrast Adaptive)"),
                                qsTr("Cinema Vivid (CAS + Vibrance + Clarity)"),
                                qsTr("Ultra Crisp (FSRCNNX x2 AI + CAS + Deband)")
                            ]
                            currentIndex: Chiaki.settings.pictureEnhanceMode
                            onActivated: index => Chiaki.settings.pictureEnhanceMode = index
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(AMD CAS)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Color Vibrance & Local Clarity:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [qsTr("Off"), qsTr("Subtle"), qsTr("Vivid")]
                            currentIndex: Chiaki.settings.vibranceLevel
                            onActivated: index => Chiaki.settings.vibranceLevel = index
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Quick Debanding (Smooth Sky & Shadows):")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.debandQuickEnabled
                            onToggled: Chiaki.settings.debandQuickEnabled = !Chiaki.settings.debandQuickEnabled
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(On)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Action On Suspend:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [qsTr("Do Nothing"), qsTr("Enter Sleep Mode")]
                            currentIndex: Chiaki.settings.suspendAction
                            onActivated: index => Chiaki.settings.suspendAction = index
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Do Nothing)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Steam Deck Haptics:")
                            visible: (typeof Chiaki.settings.steamDeckHaptics !== "undefined")
                        }

                        C.CheckBox {
                            text: qsTr("True haptics for SteamDeck, better quality but noisier")
                            checked: {
                                if(typeof Chiaki.settings.steamDeckHaptics !== "undefined")
                                    Chiaki.settings.steamDeckHaptics
                                else
                                    false
                            }
                            onToggled: Chiaki.settings.steamDeckHaptics = checked
                            visible: (typeof Chiaki.settings.steamDeckHaptics !== "undefined")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                            visible: (typeof Chiaki.settings.steamDeckHaptics !== "undefined")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Steam Deck Vertical:")
                            visible: typeof Chiaki.settings.verticalDeck !== "undefined"
                        }

                        C.CheckBox {
                            text: qsTr("Use Steam Deck in vertical orientation (motion controls)")
                            checked: {
                                if(typeof Chiaki.settings.verticalDeck !== "undefined")
                                    Chiaki.settings.verticalDeck
                                else
                                    false
                            }
                            onToggled: Chiaki.settings.verticalDeck = checked
                            visible: typeof Chiaki.settings.verticalDeck !== "undefined"
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                            visible: typeof Chiaki.settings.verticalDeck !== "undefined"
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Audio/Video:")
                        }

                        C.ComboBox {
                            Layout.preferredWidth: 400
                            model: [qsTr("Audio and Video Enabled"), qsTr("Audio Disabled"), qsTr("Video Disabled"), qsTr("Audio and Video Disabled")]
                            currentIndex: Chiaki.settings.audioVideoDisabled
                            onActivated: index => Chiaki.settings.audioVideoDisabled = index
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Audio and Video Enabled)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Log Directory:")
                        }

                        Label {
                            Layout.maximumWidth: 600
                            text: Chiaki.settings.logDirectory
                            verticalAlignment: Text.AlignVCenter
                            fontSizeMode: Text.HorizontalFit
                            minimumPixelSize: 10

                            C.Button {
                                id: openButton
                                anchors {
                                    left: parent.left
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: parent.paintedWidth + 20
                                }
                                text: qsTr("Open")
                                onClicked: Qt.openUrlExternally("file://" + parent.text);
                                Material.roundedScale: Material.SmallScale
                            }
                        }
                        Label {

                        }
                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Streamer Mode (Hides Info)")
                        }
                        C.CheckBox {
                            id: streamerMode
                            checked: Chiaki.settings.streamerMode
                            onToggled: Chiaki.settings.streamerMode = !Chiaki.settings.streamerMode
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Stream Menu Shortcut Enabled")
                        }
                        C.CheckBox {
                            id: streamMenu
                            checked: Chiaki.settings.streamMenuEnabled
                            onToggled: Chiaki.settings.streamMenuEnabled = !Chiaki.settings.streamMenuEnabled
                            KeyNavigation.priority: KeyNavigation.BeforeItem
                            KeyNavigation.up: streamerMode
                            KeyNavigation.left: streamMenu
                            KeyNavigation.right: streamMenu
                            KeyNavigation.down: {
                                if(streamMenuShortcut1.visible)
                                    streamMenuShortcut1
                                else
                                    streamMenu
                            }
                        }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(On)")
                            }
                        }
                        RowLayout {
                            spacing: 10
                            visible: Chiaki.settings.streamMenuEnabled
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Stream Menu Combo:")
                            }

                        C.ComboBox {
                            id: streamMenuShortcut1
                            implicitContentWidthPolicy: ComboBox.WidestText
                            firstInFocusChain: false
                            model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                            currentIndex: Chiaki.settings.streamMenuShortcut1
                            onActivated: index => Chiaki.settings.streamMenuShortcut1 = index
                            KeyNavigation.priority: {
                                if(!popup.visible)
                                    KeyNavigation.BeforeItem
                                else
                                    KeyNavigation.AfterItem
                            }
                            KeyNavigation.up: streamMenu
                            KeyNavigation.down: streamMenuShortcut1
                            KeyNavigation.left: streamMenuShortcut1
                            KeyNavigation.right: streamMenuShortcut2
                        }

                        C.ComboBox {
                            id: streamMenuShortcut2
                            implicitContentWidthPolicy: ComboBox.WidestText
                            firstInFocusChain: false
                            model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                            currentIndex: Chiaki.settings.streamMenuShortcut2
                            onActivated: index => Chiaki.settings.streamMenuShortcut2 = index
                            KeyNavigation.priority: {
                                if(!popup.visible)
                                    KeyNavigation.BeforeItem
                                else
                                    KeyNavigation.AfterItem
                            }
                            KeyNavigation.up: streamMenu
                            KeyNavigation.down: streamMenuShortcut2
                            KeyNavigation.left: streamMenuShortcut1
                            KeyNavigation.right: streamMenuShortcut3
                        }

                        C.ComboBox {
                            id: streamMenuShortcut3
                            implicitContentWidthPolicy: ComboBox.WidestText
                            firstInFocusChain: false
                            model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                            currentIndex: Chiaki.settings.streamMenuShortcut3
                            onActivated: index => Chiaki.settings.streamMenuShortcut3 = index
                            KeyNavigation.priority: {
                                if(!popup.visible)
                                    KeyNavigation.BeforeItem
                                else
                                    KeyNavigation.AfterItem
                            }
                            KeyNavigation.up: streamMenu
                            KeyNavigation.down: streamMenuShortcut3
                            KeyNavigation.left: streamMenuShortcut2
                            KeyNavigation.right: streamMenuShortcut4
                        }

                        C.ComboBox {
                            id: streamMenuShortcut4
                            implicitContentWidthPolicy: ComboBox.WidestText
                            firstInFocusChain: false
                            model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                            currentIndex: Chiaki.settings.streamMenuShortcut4
                            onActivated: index => Chiaki.settings.streamMenuShortcut4 = index
                            KeyNavigation.priority: {
                                if(!popup.visible)
                                    KeyNavigation.BeforeItem
                                else
                                    KeyNavigation.AfterItem
                            }
                            KeyNavigation.up: streamMenu
                            KeyNavigation.down: streamMenuShortcut4
                            KeyNavigation.left: streamMenuShortcut3
                            KeyNavigation.right: streamMenuShortcut4
                        }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(L1+R1+L3+R3)")
                            }
                        }
                    }
                }
            }

            Item {
                // Video
                Flickable {
                    id: videoFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, videoGrid.width + 140)
                    contentHeight: videoGrid.y + videoGrid.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: videoFlick.contentHeight > videoFlick.height
                    }
                    Rectangle {
                        x: videoGrid.x - 32
                        y: videoGrid.y - 28
                        width: videoGrid.width + 64
                        height: videoGrid.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: videoGrid.x - 32
                        y: 14
                        text: qsTr("Video")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: videoGrid.x - 32
                        y: 66
                        text: qsTr("Decoder, window and renderer options.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    GridLayout {
                        id: videoGrid
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        columns: 3
                        rowSpacing: 10
                        columnSpacing: 20

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Hardware Decoder:")
                        }

                    RowLayout {
                        Layout.preferredWidth: 400
                        spacing: 12

                        C.ComboBox {
                            id: hwDecoderCombo
                            Layout.preferredWidth: 220
                            model: Chiaki.settings.availableDecoders
                            currentIndex: Math.max(0, model.indexOf(Chiaki.settings.decoder))
                            KeyNavigation.priority: KeyNavigation.BeforeItem
                            KeyNavigation.up: hwDecoderCombo
                            KeyNavigation.right: zeroCopyCheck
                            KeyNavigation.down: windowTypeCombo
                            onActivated: (index) => Chiaki.settings.decoder = index ? model[index] : ""
                        }

                        Label {
                            text: qsTr("Zero-Copy")
                        }

                        C.CheckBox {
                            id: zeroCopyCheck
                            KeyNavigation.priority: KeyNavigation.BeforeItem
                            KeyNavigation.up: zeroCopyCheck
                            KeyNavigation.left: hwDecoderCombo
                            KeyNavigation.down: windowTypeCombo
                            checked: Chiaki.settings.useZeroCopy
                            onToggled: Chiaki.settings.useZeroCopy = checked
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(Auto)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Window Type:")
                    }

                    C.ComboBox {
                        id: windowTypeCombo
                        Layout.preferredWidth: 400
                        popup.width: 500
                        model: [qsTr("Stream Resolution"), qsTr("Custom Resolution"), qsTr("Adjust Resolution Manually"), qsTr("Fullscreen"), qsTr("Zoom [adjust zoom using slider in stream menu]"), qsTr("Stretch")]
                        currentIndex: Chiaki.settings.windowType
                        onActivated: (index) => Chiaki.settings.windowType = index;
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(Fullscreen)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Custom Resolution Width")
                        visible: Chiaki.settings.windowType == 1
                    }

                    C.TextField {
                        id: customResolutionWidth
                        Layout.preferredWidth: 400
                        visible: Chiaki.settings.windowType == 1
                        text: Chiaki.settings.customResolutionWidth
                        Material.accent: text && !validate() ? Material.Red : undefined
                        onEditingFinished: {
                            if (validate()) {
                                Chiaki.settings.customResolutionWidth = parseInt(text);
                            } else {
                                Chiaki.settings.customResolutionWidth = 0;
                                text = "";
                            }
                        }
                        function validate() {
                            var num = parseInt(text);
                            return num >= 0 && num <= 9999;
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(1920)")
                        visible: Chiaki.settings.windowType == 1
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Custom Resolution Height")
                        visible: Chiaki.settings.windowType == 1
                    }

                    C.TextField {
                        id: customResolutionHeight
                        Layout.preferredWidth: 400
                        visible: Chiaki.settings.windowType == 1
                        text: Chiaki.settings.customResolutionHeight
                        Material.accent: text && !validate() ? Material.Red : undefined
                        onEditingFinished: {
                            if (validate()) {
                                Chiaki.settings.customResolutionHeight = parseInt(text);
                            } else {
                                Chiaki.settings.customResolutionHeight = 0;
                                text = "";
                            }
                        }
                        function validate() {
                            var num = parseInt(text);
                            return num >= 0 && num <= 9999;
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(1080)")
                        visible: Chiaki.settings.windowType == 1
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Toggle Fullscreen on Double-click:")
                    }

                    C.CheckBox {
                        checked: Chiaki.settings.fullscreenDoubleClick
                        onToggled: Chiaki.settings.fullscreenDoubleClick = checked
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(Off)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Hide Cursor during Stream")
                    }
                    C.CheckBox {
                        checked: Chiaki.settings.hideCursor
                        onToggled: Chiaki.settings.hideCursor = !Chiaki.settings.hideCursor
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(On)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Vertical Sync:")
                    }

                    C.CheckBox {
                        checked: Chiaki.settings.vSyncEnabled
                        onClicked: {
                            // on OpenGL this needs a fresh start: see restartPending in Main.qml
                            Chiaki.settings.vSyncEnabled = checked
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(Off)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Render Preset:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 520
                        model: [qsTr("Fast"), qsTr("Default"), qsTr("High Quality"), qsTr("High Quality + Spatial Upscaling"), qsTr("High Quality + Advanced Spatial Upscaling"), qsTr("Custom")]
                        currentIndex: Chiaki.settings.videoPreset
                        onActivated: (index) => {
                            Chiaki.settings.videoPreset = index;
                            switch (index) {
                            case 0: Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Fast; break;
                            case 1: Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Default; break;
                            case 2: Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQuality; break;
                            case 3: Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQualitySpatial; break;
                            case 4: Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial; break;
                            case 5: Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Custom; break;
                            }
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(High Quality)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Frame Delivery:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("Direct Mapping"), qsTr("Frame Queue")]
                        currentIndex: Chiaki.settings.directFrameMapping ? 0 : 1
                        onActivated: (index) => {
                            const direct = index === 0;
                            if (direct === Chiaki.settings.directFrameMapping)
                                return;
                            // needs a fresh start: see restartPending in Main.qml
                            Chiaki.settings.directFrameMapping = direct;
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(Direct Mapping)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Frame Mixer:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: [qsTr("None"), qsTr("Oversample"), qsTr("Hermite"), qsTr("Linear"), qsTr("Cubic")]
                        enabled: !Chiaki.settings.directFrameMapping
                        currentIndex: Chiaki.settings.directFrameMapping ? 0 : Chiaki.settings.placeboFrameMixer
                        onActivated: index => Chiaki.settings.placeboFrameMixer = index
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(None)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Renderer Backend:")
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        model: Chiaki.macOs
                            ? [qsTr("Vulkan over Apple Metal (Recommended)"), qsTr("OpenGL (Legacy Compatibility)")]
                            : [qsTr("Vulkan"), qsTr("OpenGL")]
                        currentIndex: Chiaki.settings.rendererBackend
                        onActivated: (index) => {
                            if (index === Chiaki.settings.rendererBackend)
                                return;
                            // needs a fresh start: see restartPending in Main.qml
                            Chiaki.settings.rendererBackend = index;
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: Chiaki.macOs ? qsTr("(Metal / Vulkan)") : qsTr("(Vulkan)")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("macOS Vulkan → Metal Driver:")
                        visible: Chiaki.macOs && Chiaki.settings.rendererBackend == 0
                    }

                    C.ComboBox {
                        Layout.preferredWidth: 400
                        visible: Chiaki.macOs && Chiaki.settings.rendererBackend == 0
                        model: [
                            qsTr("Auto (KosmicKrisp Metal 4 if installed, else MoltenVK)"),
                            qsTr("MoltenVK 1.4 (Khronos Vulkan → Metal)"),
                            qsTr("KosmicKrisp (LunarG Mesa Vulkan 1.4 → Metal 4)"),
                            qsTr("System Default (VK_DRIVER_FILES / All ICDs)")
                        ]
                        currentIndex: {
                            switch (Chiaki.settings.macVulkanDriver) {
                            case "moltenvk": return 1;
                            case "kosmickrisp": return 2;
                            case "system": return 3;
                            default: return 0;
                            }
                        }
                        onActivated: (index) => {
                            const vals = ["auto", "moltenvk", "kosmickrisp", "system"];
                            if (vals[index] === Chiaki.settings.macVulkanDriver)
                                return;
                            Chiaki.settings.macVulkanDriver = vals[index];
                            root.restartPending = true;
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        Layout.maximumWidth: 420
                        color: "#A08F84"
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                        visible: Chiaki.macOs && Chiaki.settings.rendererBackend == 0
                        text: qsTr("Detected: %1").arg(Chiaki.settings.availableMacVulkanDrivers.length > 0 ? Chiaki.settings.availableMacVulkanDrivers.join(", ") : qsTr("None"))
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("MoltenVK Metal 3 Argument Buffers:")
                        visible: Chiaki.macOs && Chiaki.settings.rendererBackend == 0
                    }

                    C.CheckBox {
                        checked: Chiaki.settings.moltenVkArgBuffers
                        onToggled: {
                            Chiaki.settings.moltenVkArgBuffers = checked;
                            root.restartPending = true;
                        }
                        visible: Chiaki.macOs && Chiaki.settings.rendererBackend == 0
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        Layout.maximumWidth: 420
                        color: "#A08F84"
                        font.pixelSize: 13
                        wrapMode: Text.Wrap
                        visible: Chiaki.macOs && Chiaki.settings.rendererBackend == 0
                        text: qsTr("(On) Faster Metal 3 descriptor binding on Apple Silicon (requires restart).")
                    }

                    Label {
                        Layout.columnSpan: 3
                        Layout.fillWidth: true
                        visible: root.restartPending
                        text: qsTr("Takes effect after Robz Play restarts. You will be asked when you leave the settings.")
                        color: "#D9A65A"
                        font.pixelSize: 14
                        wrapMode: Text.Wrap
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Vulkan Deferred Swap:")
                        visible: Chiaki.settings.rendererBackend == 0
                    }

                    C.CheckBox {
                        checked: Chiaki.settings.vulkanDeferredSwap
                        onToggled: Chiaki.settings.vulkanDeferredSwap = checked
                        visible: Chiaki.settings.rendererBackend == 0
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        color: "#A08F84"
                        font.pixelSize: 14
                        text: qsTr("(Off)")
                        visible: Chiaki.settings.rendererBackend == 0
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Custom Renderer Settings")
                        visible: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom
                    }

                    C.Button {
                        id: customRendererSettings
                        text: qsTr("Open")
                        onClicked: root.showPlaceboSettingsDialog()
                        Material.roundedScale: Material.SmallScale
                        visible: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom
                    }

                    Label { visible: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Display Settings")
                    }

                    C.Button {
                        id: displaySettings
                        text: qsTr("Open")
                        onClicked: root.showDisplaySettingsDialog()
                        Material.roundedScale: Material.SmallScale
                        lastInFocusChain: true
                    }

                    Label {}
                    }
                }
            }

            Item {
                // Stream
                Flickable {
                    id: streamFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, streamGrid.width + 140)
                    contentHeight: streamGrid.y + streamGrid.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: streamFlick.contentHeight > streamFlick.height
                    }
                    Rectangle {
                        x: streamGrid.x - 32
                        y: streamGrid.y - 28
                        width: streamGrid.width + 64
                        height: streamGrid.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: streamGrid.x - 32
                        y: 14
                        text: qsTr("Stream")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: streamGrid.x - 32
                        y: 66
                        text: qsTr("Resolution, frame rate, bitrate and codec for each console.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    GridLayout {
                        id: streamGrid
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        columns: 3
                        rowSpacing: 10
                        columnSpacing: 20

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Settings for:")
                        }


                    C.ComboBox {
                        id: consoleSelection
                        Layout.preferredWidth: 400
                        Layout.alignment: Qt.AlignLeft
                        model: [qsTr("PS4"), qsTr("PS5")]
                        currentIndex: selectedConsole
                        onActivated: (index) => selectedConsole = index
                        firstInFocusChain: true
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                        KeyNavigation.down: {
                            if(selectedConsole == SettingsDialog.Console.PS4)
                                resolutionLocalPS4
                            else
                                resolutionLocalPS5

                        }

                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("")
                    }

                    Label {
                        Layout.alignment: Qt.AlignCenter
                        text: qsTr("Local")
                    }

                    Label {
                        Layout.alignment: Qt.AlignCenter
                        text: qsTr("Remote")
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Resolution:")
                    }

                    C.ComboBox {
                        id: resolutionLocalPS4
                        Layout.preferredWidth: 400
                        model: [qsTr("360p"), qsTr("540p"), qsTr("720p (Default)"), qsTr("1080p (PS5 and PS4 Pro)")]
                        currentIndex: Chiaki.settings.resolutionLocalPS4 - 1
                        onActivated: (index) => {
                            Chiaki.settings.resolutionLocalPS4 = index + 1
                            Chiaki.settings.bitrateLocalPS4 = 0
                        }
                        visible: selectedConsole == SettingsDialog.Console.PS4
                        KeyNavigation.right: resolutionRemotePS4
                        KeyNavigation.down: fpsLocalPS4
                        KeyNavigation.up: consoleSelection
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    C.ComboBox {
                        id: resolutionRemotePS4
                        Layout.preferredWidth: 400
                        model: [qsTr("360p"), qsTr("540p"), qsTr("720p (Default)"), qsTr("1080p (PS5 and PS4 Pro)")]
                        currentIndex: Chiaki.settings.resolutionRemotePS4 - 1
                        onActivated: (index) => {
                            Chiaki.settings.resolutionRemotePS4 = index + 1
                            Chiaki.settings.bitrateRemotePS4 = 0
                        }
                        visible: selectedConsole == SettingsDialog.Console.PS4
                        KeyNavigation.left: resolutionLocalPS4
                        KeyNavigation.down: fpsRemotePS4
                        KeyNavigation.up: consoleSelection
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    C.ComboBox {
                        id: resolutionLocalPS5
                        Layout.preferredWidth: 400
                        model: [qsTr("360p"), qsTr("540p"), qsTr("720p"), qsTr("1080p (Default)")]
                        currentIndex: Chiaki.settings.resolutionLocalPS5 - 1
                        // the bitrate stays as it is: Robz Play's default is 100 Mbps at every resolution
                        onActivated: (index) => Chiaki.settings.resolutionLocalPS5 = index + 1
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        KeyNavigation.right: resolutionRemotePS5
                        KeyNavigation.up: consoleSelection
                        KeyNavigation.down: fpsLocalPS5
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    C.ComboBox {
                        id: resolutionRemotePS5
                        Layout.preferredWidth: 400
                        model: [qsTr("360p"), qsTr("540p"), qsTr("720p"), qsTr("1080p (Default)")]
                        currentIndex: Chiaki.settings.resolutionRemotePS5 - 1
                        // the bitrate stays as it is: Robz Play's default is 100 Mbps at every resolution
                        onActivated: (index) => Chiaki.settings.resolutionRemotePS5 = index + 1
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        KeyNavigation.left: resolutionLocalPS5
                        KeyNavigation.up: consoleSelection
                        KeyNavigation.down: fpsRemotePS5
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("FPS:")
                    }

                    C.ComboBox {
                        id: fpsLocalPS4
                        Layout.preferredWidth: 400
                        model: [qsTr("30 fps"), qsTr("60 fps (Default)")]
                        currentIndex: (Chiaki.settings.fpsLocalPS4 / 30) - 1
                        onActivated: (index) => Chiaki.settings.fpsLocalPS4 = (index + 1) * 30
                        visible: selectedConsole == SettingsDialog.Console.PS4
                        KeyNavigation.up: resolutionLocalPS4
                        KeyNavigation.right: fpsRemotePS4
                        KeyNavigation.down: bitrateLocalPS4
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    C.ComboBox {
                        id: fpsRemotePS4
                        Layout.preferredWidth: 400
                        model: [qsTr("30 fps"), qsTr("60 fps (Default)")]
                        currentIndex: (Chiaki.settings.fpsRemotePS4 / 30) - 1
                        onActivated: (index) => Chiaki.settings.fpsRemotePS4 = (index + 1) * 30
                        visible: selectedConsole == SettingsDialog.Console.PS4
                        KeyNavigation.up: resolutionRemotePS4
                        KeyNavigation.left: fpsLocalPS4
                        KeyNavigation.down: bitrateRemotePS4
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    C.ComboBox {
                        id: fpsLocalPS5
                        Layout.preferredWidth: 400
                        model: [qsTr("30 fps"), qsTr("60 fps (Default)")]
                        currentIndex: (Chiaki.settings.fpsLocalPS5 / 30) - 1
                        onActivated: (index) => Chiaki.settings.fpsLocalPS5 = (index + 1) * 30
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        KeyNavigation.up: resolutionLocalPS5
                        KeyNavigation.right: fpsRemotePS5
                        KeyNavigation.down: bitrateLocalPS5
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    C.ComboBox {
                        id: fpsRemotePS5
                        Layout.preferredWidth: 400
                        model: [qsTr("30 fps"), qsTr("60 fps (Default)")]
                        currentIndex: (Chiaki.settings.fpsRemotePS5 / 30) - 1
                        onActivated: (index) => Chiaki.settings.fpsRemotePS5 = (index + 1) * 30
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        KeyNavigation.up: resolutionRemotePS5
                        KeyNavigation.left: fpsLocalPS5
                        KeyNavigation.down: bitrateRemotePS5
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Bitrate:")
                    }

                    C.Slider {
                        id: bitrateLocalPS4
                        visible: selectedConsole == SettingsDialog.Console.PS4
                        property var bitrate: {
                            var rate = 0;
                            switch (Chiaki.settings.resolutionLocalPS4) {
                            case 1: rate = 2; break; // 360p
                            case 2: rate = 6; break; // 540p
                            case 3: rate = 10; break; // 720p
                            case 4: rate = 15; break; // 1080p
                            }
                            return rate;
                        }
                        Layout.preferredWidth: 200
                        from: 2
                        to: 100
                        stepSize: 1
                        value: Chiaki.settings.bitrateLocalPS4 / 1000 ? (Chiaki.settings.bitrateLocalPS4 / 1000) : bitrate
                        onMoved: Chiaki.settings.bitrateLocalPS4 = value * 1000;
                        KeyNavigation.up: fpsLocalPS4
                        KeyNavigation.down: bitrateLocalPS4
                        KeyNavigation.priority: KeyNavigation.BeforeItem
                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: (parent.value) + qsTr(" Mbps") + qsTr(" (%1 Mbps)").arg(parent.bitrate.toFixed(0))
                        }
                    }

                    C.Slider {
                        id: bitrateRemotePS4
                        visible: selectedConsole == SettingsDialog.Console.PS4
                        property var bitrate: {
                            var rate = 0;
                            switch (Chiaki.settings.resolutionRemotePS4) {
                            case 1: rate = 2; break; // 360p
                            case 2: rate = 6; break; // 540p
                            case 3: rate = 10; break; // 720p
                            case 4: rate = 15; break; // 1080p
                            }
                            return rate;
                        }
                        Layout.preferredWidth: 200
                        from: 2
                        to: 100
                        stepSize: 1
                        value: Chiaki.settings.bitrateRemotePS4 / 1000 ? (Chiaki.settings.bitrateRemotePS4 / 1000) : bitrate
                        onMoved: Chiaki.settings.bitrateRemotePS4 = value * 1000;
                        KeyNavigation.up: fpsRemotePS4
                        KeyNavigation.down: bitrateRemotePS4
                        KeyNavigation.priority: KeyNavigation.BeforeItem
                        lastInFocusChain: true

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: (parent.value) + qsTr(" Mbps") + qsTr(" (%1 Mbps)").arg(parent.bitrate.toFixed(0))
                        }
                    }

                    C.Slider {
                        id: bitrateLocalPS5
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        property var bitrate: {
                            var rate = 0;
                            switch (Chiaki.settings.resolutionLocalPS5) {
                            case 1: rate = 2; break; // 360p
                            case 2: rate = 6; break; // 540p
                            case 3: rate = 10; break; // 720p
                            case 4: rate = 15; break; // 1080p
                            }
                            return rate;
                        }
                        Layout.preferredWidth: 200
                        from: 2
                        to: 100
                        stepSize: 1
                        value: Chiaki.settings.bitrateLocalPS5 / 1000 ? (Chiaki.settings.bitrateLocalPS5 / 1000) : bitrate
                        onMoved: Chiaki.settings.bitrateLocalPS5 = value * 1000;
                        KeyNavigation.up: fpsLocalPS5
                        KeyNavigation.down: codecLocalPS5
                        KeyNavigation.priority: KeyNavigation.BeforeItem

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: (parent.value) + qsTr(" Mbps") + qsTr(" (%1 Mbps)").arg(100)
                        }
                    }

                    C.Slider {
                        id: bitrateRemotePS5
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        property var bitrate: {
                            var rate = 0;
                            switch (Chiaki.settings.resolutionRemotePS5) {
                            case 1: rate = 2; break; // 360p
                            case 2: rate = 6; break; // 540p
                            case 3: rate = 10; break; // 720p
                            case 4: rate = 15; break; // 1080p
                            }
                            return rate;
                        }
                        Layout.preferredWidth: 200
                        from: 2
                        to: 100
                        stepSize: 1
                        value: Chiaki.settings.bitrateRemotePS5 / 1000 ? (Chiaki.settings.bitrateRemotePS5 / 1000) : bitrate
                        onMoved: Chiaki.settings.bitrateRemotePS5 = value * 1000;
                        KeyNavigation.up: fpsRemotePS5
                        KeyNavigation.down: codecRemotePS5
                        KeyNavigation.priority: KeyNavigation.BeforeItem
                        lastInFocusChain: true

                        Label {
                            anchors {
                                left: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 10
                            }
                            text: (parent.value) + qsTr(" Mbps") + qsTr(" (%1 Mbps)").arg(100)
                        }
                    }

                    Label {
                        Layout.alignment: Qt.AlignLeft
                        text: qsTr("Codec:")
                        visible: selectedConsole == SettingsDialog.Console.PS5
                    }

                    C.ComboBox {
                        id: codecLocalPS5
                        Layout.preferredWidth: 400
                        property bool openGlBackend: Chiaki.settings.rendererBackend === 1
						model: openGlBackend ? [qsTr("H264"), qsTr("H265 (Default)")] : [qsTr("H264"), qsTr("H265 (Default)"), qsTr("H265 HDR")]
                        currentIndex: Chiaki.settings.codecLocalPS5
                        onActivated: (index) => Chiaki.settings.codecLocalPS5 = index
                        visible: selectedConsole == SettingsDialog.Console.PS5
                        Keys.onReturnPressed: {
                            if (popup.visible) {
                                activated(highlightedIndex);
                                popup.close();
                            } else
                                popup.open();
                        }
                        KeyNavigation.up: bitrateLocalPS5
                        KeyNavigation.right: codecRemotePS5
                        KeyNavigation.down: codecLocalPS5
                        KeyNavigation.priority: {
                            if(!popup.visible)
                                KeyNavigation.BeforeItem
                            else
                                KeyNavigation.AfterItem
                        }
                    }

                        C.ComboBox {
                            id: codecRemotePS5
                            Layout.preferredWidth: 400
                        property bool openGlBackend: Chiaki.settings.rendererBackend === 1
                        model: openGlBackend ? [qsTr("H264"), qsTr("H265 (Default)")] : [qsTr("H264"), qsTr("H265 (Default)"), qsTr("H265 HDR")]
                            currentIndex: Chiaki.settings.codecRemotePS5
                            onActivated: (index) => Chiaki.settings.codecRemotePS5 = index
                            visible: selectedConsole == SettingsDialog.Console.PS5
                            lastInFocusChain: true
                            Keys.onReturnPressed: {
                                if (popup.visible) {
                                    activated(highlightedIndex);
                                    popup.close();
                                } else
                                    popup.open();
                            }
                            KeyNavigation.up: bitrateRemotePS5
                            KeyNavigation.left: codecLocalPS5
                            KeyNavigation.priority: {
                                if(!popup.visible)
                                    KeyNavigation.BeforeItem
                                else
                                    KeyNavigation.AfterItem
                            }
                        }
                    }
                }
            }

            Item {
                // Audio and Wifi
                Flickable {
                    id: audiowifiFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, audiowifigrid.width + 140)
                    contentHeight: audiowifigrid.y + audiowifigrid.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        id: audiowifiScrollbar
                        policy: ScrollBar.AlwaysOn
                        visible: audiowifiFlick.contentHeight > audiowifiFlick.height
                    }
                    Rectangle {
                        x: audiowifigrid.x - 32
                        y: audiowifigrid.y - 28
                        width: audiowifigrid.width + 64
                        height: audiowifigrid.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: audiowifigrid.x - 32
                        y: 14
                        text: qsTr("Audio and network")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: audiowifigrid.x - 32
                        y: 66
                        text: qsTr("Sound devices, volume and connection warnings.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    GridLayout {
                        id: audiowifigrid
                        columns: 3
                        rowSpacing: 10
                        columnSpacing: 20
                        onVisibleChanged: if (visible) Chiaki.settings.refreshAudioDevices()

                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Output Device:")
                        }

                        C.ComboBox {
                            id: audioOutDevice
                            Layout.preferredWidth: 400
                            popup.x: (width - popup.width) / 2
                            popup.width: 700
                            popup.font.pixelSize: 16
                            firstInFocusChain: true
                            model: [qsTr("Auto")].concat(Chiaki.settings.availableAudioOutDevices)
                            currentIndex: Math.max(0, model.indexOf(Chiaki.settings.audioOutDevice))
                            onActivated: (index) => Chiaki.settings.audioOutDevice = index ? model[index] : ""
                            KeyNavigation.down: audioInDevice
                            KeyNavigation.priority: popup.visible ? KeyNavigation.AfterItem : KeyNavigation.BeforeItem
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Auto)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Input Device:")
                        }

                        C.ComboBox {
                            id: audioInDevice
                            Layout.preferredWidth: 400
                            popup.x: (width - popup.width) / 2
                            popup.width: 700
                            popup.font.pixelSize: 16
                            model: [qsTr("Auto")].concat(Chiaki.settings.availableAudioInDevices)
                            currentIndex: Math.max(0, model.indexOf(Chiaki.settings.audioInDevice))
                            onActivated: (index) => Chiaki.settings.audioInDevice = index ? model[index] : ""
                            KeyNavigation.up: audioOutDevice
                            KeyNavigation.down: audioBufferSizeSlider
                            KeyNavigation.priority: popup.visible ? KeyNavigation.AfterItem : KeyNavigation.BeforeItem
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Auto)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Audio Buffer Size:")
                        }

                        C.Slider {
                            id: audioBufferSizeSlider
                            Layout.preferredWidth: 250
                            from: 1
                            to: 10
                            stepSize: 1
                            value: Chiaki.settings.audioBufferSize / 1920 ? (Chiaki.settings.audioBufferSize / 1920) : 5
                            onMoved: Chiaki.settings.audioBufferSize = value * 1920;
                            KeyNavigation.up: audioInDevice

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: {
                                    (parent.value * 10).toFixed(0) + qsTr(" ms")
                                }
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(50 ms)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Audio Volume:")
                        }

                        C.Slider {
                            Layout.preferredWidth: 250
                            from: 0
                            to: 128
                            stepSize: 1
                            value: Chiaki.settings.audioVolume
                            onMoved: Chiaki.settings.audioVolume = value

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: {
                                    ((parent.value / 128.0) * 100).toFixed(0) + qsTr("% volume")
                                }
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(100%)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Start Mic Unmuted:")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.startMicUnmuted
                            onToggled: Chiaki.settings.startMicUnmuted = checked
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Speech Processing:")
                            visible: typeof Chiaki.settings.speechProcessing !== "undefined"
                        }

                        C.CheckBox {
                            text: qsTr("Noise suppression + echo cancellation")
                            checked: Chiaki.settings.speechProcessing
                            onToggled: Chiaki.settings.speechProcessing = !Chiaki.settings.speechProcessing
                            visible: typeof Chiaki.settings.speechProcessing !== "undefined"
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                            visible: typeof Chiaki.settings.speechProcessing !== "undefined"
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Noise To Suppress:")
                            visible: if (typeof Chiaki.settings.speechProcessing !== "undefined") {Chiaki.settings.speechProcessing} else {false}
                        }

                        C.Slider {
                            Layout.preferredWidth: 250
                            from: 0
                            to: 60
                            stepSize: 1
                            visible: if (typeof Chiaki.settings.speechProcessing !== "undefined") {Chiaki.settings.speechProcessing} else {false}
                            value: Chiaki.settings.noiseSuppressLevel
                            onMoved: Chiaki.settings.noiseSuppressLevel = value

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: qsTr("%1 dB").arg(parent.value)
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(6 dB)")
                            visible: if (typeof Chiaki.settings.speechProcessing !== "undefined") {Chiaki.settings.speechProcessing} else {false}
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Echo To Suppress:")
                            visible: if (typeof Chiaki.settings.speechProcessing !== "undefined") {Chiaki.settings.speechProcessing} else {false}
                        }

                        C.Slider {
                            Layout.preferredWidth: 250
                            from: 0
                            to: 60
                            stepSize: 1
                            value: Chiaki.settings.echoSuppressLevel
                            visible: if (typeof Chiaki.settings.speechProcessing !== "undefined") {Chiaki.settings.speechProcessing} else {false}
                            onMoved: Chiaki.settings.echoSuppressLevel = value

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: qsTr("%1 dB").arg(parent.value)
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(30 dB)")
                            visible: if (typeof Chiaki.settings.speechProcessing !== "undefined") {Chiaki.settings.speechProcessing} else {false}
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Weak Wifi Notification:")
                        }

                        C.Slider {
                            Layout.preferredWidth: 250
                            from: 0
                            to: 100
                            stepSize: 1
                            value: Chiaki.settings.wifiDroppedNotif
                            onMoved: Chiaki.settings.wifiDroppedNotif = value

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: qsTr(">= %1% dropped packets").arg(parent.value)
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(3%)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Packet Loss Reported Max:")
                        }

                        C.Slider {
                            Layout.preferredWidth: 250
                            from: 0
                            to: 100
                            stepSize: 1
                            value: Chiaki.settings.packetLossReportedMax
                            onMoved: Chiaki.settings.packetLossReportedMax = value

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: qsTr("%1% packet loss").arg(parent.value)
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(5%)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Request IDR Frame on FEC Failure")
                        }

                        C.CheckBox {
                            checked: Chiaki.settings.iDROnFECFailureEnabled
                            onToggled: Chiaki.settings.iDROnFECFailureEnabled = !Chiaki.settings.iDROnFECFailureEnabled
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Show Stream Stats During Gameplay")
                        }

                        C.CheckBox {
                            lastInFocusChain: true
                            checked: Chiaki.settings.showStreamStats
                            onToggled: Chiaki.settings.showStreamStats = !Chiaki.settings.showStreamStats
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                        }
                    }
                }
            }

            Item {
                // Consoles
                Flickable {
                    id: consolesFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, consolesLayout.width + 140)
                    contentHeight: consolesLayout.y + consolesLayout.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: consolesFlick.contentHeight > consolesFlick.height
                    }
                    Rectangle {
                        x: consolesLayout.x - 32
                        y: consolesLayout.y - 28
                        width: consolesLayout.width + 64
                        height: consolesLayout.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: consolesLayout.x - 32
                        y: 14
                        text: qsTr("Consoles")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: consolesLayout.x - 32
                        y: 66
                        text: qsTr("Registered, hidden and manually added consoles.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    ColumnLayout {
                        id: consolesLayout
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        spacing: 10

                        Label {
                            text: ""
                        }

                        Label {
                            text: ""
                        }

                        C.Button {
                            id: registerNewButton
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 10
                            topPadding: 26
                            leftPadding: 30
                            rightPadding: 30
                            bottomPadding: 26
                            firstInFocusChain: true
                            text: qsTr("Register New")
                            onClicked: root.showRegistDialog("255.255.255.255", true)
                            Material.roundedScale: Material.SmallScale
                        }

                        Label {
                            id: consolesLabel
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Registered Consoles")
                            font.bold: true
                        }

                        ListView {
                            id: consolesView
                            Layout.alignment: Qt.AlignHCenter
                            height: 170
                            onCountChanged: {
                                consolesView.contentHeight = consolesView.count * 80 + consolesView.anchors.topMargin;
                            }
                            keyNavigationEnabled: false
                            width: 700
                            ScrollBar.vertical: ScrollBar {
                                id: consolesScrollbar
                                policy: ScrollBar.AlwaysOn
                                visible: consolesView.contentHeight > consolesView.height
                            }
                            clip: true
                            model: Chiaki.settings.registeredHosts
                            delegate: ItemDelegate {
                                text: "%1 (%2, %3)".arg(Chiaki.settings.streamerMode ? qsTr("hidden") : modelData.mac).arg(modelData.ps5 ? "PS5" : "PS4").arg(modelData.name)
                                height: 80
                                width: parent ? parent.width : 0
                                leftPadding: autoConnectButton.width + 40

                                CheckBox {
                                    property bool firstInFocusChain: false
                                    property bool lastInFocusChain: false
                                    property bool lastDownInFocusChain: index > consolesView.count + hiddenConsolesView.count - 2

                                    id: autoConnectButton
                                    anchors {
                                        left: parent.left
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: 20
                                    }
                                    text: qsTr("Auto-Connect")
                                    checked: Chiaki.settings.autoConnectMac == modelData.mac
                                    onToggled: Chiaki.settings.autoConnectMac = checked ? modelData.mac : "";

                                    Keys.onPressed: (event) => {
                                        switch (event.key) {
                                        case Qt.Key_Right:
                                            if (!lastInFocusChain) {
                                                let item = nextItemInFocusChain();
                                                if (item)
                                                    item.forceActiveFocus(Qt.TabFocusReason);
                                                event.accepted = true;
                                            }
                                            break;
                                        case Qt.Key_Up:
                                            if (!firstInFocusChain) {
                                                let item = nextItemInFocusChain(false);
                                                if (item) {
                                                    item.forceActiveFocus(Qt.TabFocusReason);
                                                    dialog.ensureItemVisibleInFlick(consolesView, item);
                                                }
                                                let count = index > 0 ? 2: 0;
                                                for(var i = 0; i < count; i++)
                                                {
                                                    let item2 = item.nextItemInFocusChain(false);
                                                    if (item)
                                                    {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        dialog.ensureItemVisibleInFlick(consolesView, item);
                                                        item = item2;
                                                    }
                                                }
                                                event.accepted = true;
                                            }
                                            break;
                                        case Qt.Key_Down:
                                            if (!lastDownInFocusChain) {
                                                let item = nextItemInFocusChain();
                                                if (item) {
                                                    item.forceActiveFocus(Qt.TabFocusReason);
                                                    dialog.ensureItemVisibleInFlick(consolesView, item);
                                                }
                                                let count = 2;
                                                for(var i = 0; i < count; i++)
                                                {
                                                    let item2 = item.nextItemInFocusChain();
                                                    if (item)
                                                    {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        dialog.ensureItemVisibleInFlick(consolesView, item);
                                                        item = item2;
                                                    }
                                                }
                                                event.accepted = true;
                                            }
                                            break;
                                        case Qt.Key_Return:
                                            if (visualFocus) {
                                                toggle();
                                                toggled();
                                            }
                                            event.accepted = true;
                                            break;
                                        }
                                    }
                                }

                                Button {
                                    property bool firstInFocusChain: false
                                    property bool lastInFocusChain: index > consolesView.count + hiddenConsolesView.count - 2
                                    Material.background: visualFocus ? Material.accent : undefined

                                    Component.onDestruction: {
                                        if (visualFocus) {
                                            let item = nextItemInFocusChain();
                                            if (item)
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                        }
                                    }
                                    Keys.onPressed: (event) => {
                                        switch (event.key) {
                                            case Qt.Key_Left:
                                                if (!firstInFocusChain) {
                                                    let item = nextItemInFocusChain(false);
                                                    if (item)
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Up:
                                                if (!firstInFocusChain)
                                                {
                                                    let item = nextItemInFocusChain(false);
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        dialog.ensureItemVisibleInFlick(consolesView, item);
                                                    }
                                                    let count = 2;
                                                    for(var i = 0; i < count; i++)
                                                    {
                                                        let item2 = item.nextItemInFocusChain(false);
                                                        if (item)
                                                        {
                                                            item.forceActiveFocus(Qt.TabFocusReason);
                                                            dialog.ensureItemVisibleInFlick(consolesView, item);
                                                            item = item2;
                                                        }
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Down:
                                                if (!lastInFocusChain) {
                                                    let item = nextItemInFocusChain();
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        dialog.ensureItemVisibleInFlick(consolesView, item);
                                                    }
                                                    let count = index < consolesView.count - 1 ? 2: 0;
                                                    for(var i = 0; i < count; i++)
                                                    {
                                                        let item2 = item.nextItemInFocusChain();
                                                        if (item)
                                                        {
                                                            item.forceActiveFocus(Qt.TabFocusReason);
                                                            dialog.ensureItemVisibleInFlick(consolesView, item);
                                                            item = item2;
                                                        }
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Return:
                                                if (visualFocus) {
                                                    clicked();
                                                }
                                                event.accepted = true;
                                                break;
                                        }
                                    }
                                    anchors {
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        rightMargin: 20
                                    }
                                    text: qsTr("Delete")
                                    onClicked: root.showConfirmDialog(qsTr("Delete Console"), qsTr("Are you sure you want to delete this console?"), () => Chiaki.settings.deleteRegisteredHost(index));
                                    Material.roundedScale: Material.SmallScale
                                    Material.accent: Material.Red
                                }
                            }
                        }

                        Label {
                            id: hiddenConsolesLabel
                            Layout.alignment: Qt.AlignHCenter
                            text: qsTr("Hidden Consoles")
                            font.bold: true
                        }
                        ListView {
                            id: hiddenConsolesView
                            Layout.alignment: Qt.AlignHCenter
                            keyNavigationEnabled: false
                            height: 170
                            onCountChanged: {
                                hiddenConsolesView.contentHeight = hiddenConsolesView.count * 80 + hiddenConsolesView.anchors.topMargin;
                            }
                            clip: true
                            width: 500
                            ScrollBar.vertical: ScrollBar {
                                id: hiddenConsolesScrollbar
                                policy: ScrollBar.AlwaysOn
                                visible: hiddenConsolesView.contentHeight > hiddenConsolesView.height
                            }
                            model: Chiaki.hiddenHosts
                            delegate: ItemDelegate {
                                text: "%1 (%2)".arg(Chiaki.settings.streamerMode ? qsTr("hidden") : modelData.mac).arg(modelData.name)
                                height: 80
                                width: parent ? parent.width : 0

                                Button {
                                    property bool firstInFocusChain: false
                                    property bool lastInFocusChain: index > hiddenConsolesView.count - 2
                                    Material.background: visualFocus ? Material.accent : undefined

                                    Component.onDestruction: {
                                        if (visualFocus) {
                                            let item = nextItemInFocusChain();
                                            if (item)
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                        }
                                    }
                                    Keys.onPressed: (event) => {
                                        switch (event.key) {
                                            case Qt.Key_Up:
                                                if (!firstInFocusChain)
                                                {
                                                    let item = nextItemInFocusChain(false);
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        dialog.ensureItemVisibleInFlick(hiddenConsolesView, item);
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Down:
                                                if (!lastInFocusChain) {
                                                    let item = nextItemInFocusChain();
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        dialog.ensureItemVisibleInFlick(hiddenConsolesView, item);
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Return:
                                                if (visualFocus) {
                                                    clicked();
                                                }
                                                event.accepted = true;
                                                break;
                                        }
                                    }
                                    anchors {
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                        rightMargin: 20
                                    }
                                    text: qsTr("Unhide")
                                    onClicked: root.showConfirmDialog(qsTr("Unhide Console"), qsTr("Are you sure you want to unhide this console?"), () => Chiaki.unhideHost(modelData.mac));
                                    Material.roundedScale: Material.SmallScale
                                    Material.accent: Material.Red
                                }
                            }
                        }
                    }
                }
            }

            Item {
                // Keys
                id: controllerMapping
                Flickable {
                    id: keysFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, keysGrid.width + 140)
                    contentHeight: keysGrid.y + keysGrid.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    function ensureItemVisible(item) {
                        if (!item)
                            return;
                        const top = item.mapToItem(keysGrid, 0, 0).y;
                        const bottom = top + item.height;
                        if (top < contentY)
                            contentY = top;
                        else if (bottom > contentY + height)
                            contentY = bottom - height;
                    }
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: keysFlick.contentHeight > keysFlick.height
                    }
                    Rectangle {
                        x: keysGrid.x - 32
                        y: keysGrid.y - 28
                        width: keysGrid.width + 64
                        height: keysGrid.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: keysGrid.x - 32
                        y: 14
                        text: qsTr("Keyboard")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: keysGrid.x - 32
                        y: 66
                        text: qsTr("Keys used in place of controller buttons.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    GridLayout {
                        id: keysGrid
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        columns: 3
                        rowSpacing: 3
                        columnSpacing: 10

                        Button {
                            id: resetAllKeys
                            text: qsTr("Reset All Keys")
                            Layout.alignment: Qt.AlignRight
                            property bool firstInFocusChain: true
                            property bool lastInFocusChain: false
                            onClicked: Chiaki.settings.clearKeyMapping()
                            Material.roundedScale: Material.SmallScale
                            Material.background: visualFocus ? Material.accent : undefined
                            onActiveFocusChanged: if (activeFocus) keysFlick.ensureItemVisible(this)

                            Component.onDestruction: {
                                if (visualFocus) {
                                    let item = nextItemInFocusChain();
                                    if (item)
                                        item.forceActiveFocus(Qt.TabFocusReason);
                                }
                            }
                            Keys.onPressed: (event) => {
                                switch (event.key) {
                                case Qt.Key_Down:
                                    if (!lastInFocusChain) {
                                        let item = nextItemInFocusChain();
                                        if (item) {
                                            item.forceActiveFocus(Qt.TabFocusReason);
                                            keysFlick.ensureItemVisible(item);
                                        }
                                        for(var i = 0; i < 3; i++)
                                        {
                                            let item2 = item.nextItemInFocusChain();
                                            if (item)
                                            {
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                                keysFlick.ensureItemVisible(item);
                                                item = item2;
                                            }
                                        }
                                        event.accepted = true;
                                    }
                                    break;
                                case Qt.Key_Right:
                                    if (!lastInFocusChain) {
                                        let item = nextItemInFocusChain();
                                        if (item) {
                                            item.forceActiveFocus(Qt.TabFocusReason);
                                            keysFlick.ensureItemVisible(item);
                                        }
                                        event.accepted = true;
                                    }
                                    break;
                                case Qt.Key_Return:
                                    if (visualFocus) {
                                        clicked();
                                    }
                                    event.accepted = true;
                                    break;
                                }
                            }
                        }

                        CheckBox {
                            text: qsTr("Keyboard as controller")
                            checked: {
                                Chiaki.settings.keyboardEnabled
                            }
                            onToggled: Chiaki.settings.keyboardEnabled = checked
                            Layout.alignment: Qt.AlignRight
                            property bool firstInFocusChain: false
                            property bool lastInFocusChain: false
                            Material.roundedScale: Material.SmallScale
                            Material.background: visualFocus ? Material.accent : undefined
                            onActiveFocusChanged: if (activeFocus) keysFlick.ensureItemVisible(this)

                            Component.onDestruction: {
                                if (visualFocus) {
                                    let item = nextItemInFocusChain();
                                    if (item)
                                        item.forceActiveFocus(Qt.TabFocusReason);
                                }
                            }
                            Keys.onPressed: (event) => {
                                switch (event.key) {
                                    case Qt.Key_Left:
                                        if (!firstInFocusChain) {
                                            let item = nextItemInFocusChain(false);
                                            if (item) {
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                                keysFlick.ensureItemVisible(item);
                                            }
                                            event.accepted = true;
                                        }
                                        break;
                                    case Qt.Key_Right:
                                        if  (!lastInFocusChain) {
                                            let item = nextItemInFocusChain();
                                            if (item) {
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                                keysFlick.ensureItemVisible(item);
                                            }
                                            event.accepted = true;
                                        }
                                        break;
                                    case Qt.Key_Down:
                                        if (!lastInFocusChain) {
                                            let item = nextItemInFocusChain();
                                            if (item) {
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                                keysFlick.ensureItemVisible(item);
                                            }
                                            for(var i = 0; i < 3; i++)
                                            {
                                                let item2 = item.nextItemInFocusChain();
                                                if (item)
                                                {
                                                    item.forceActiveFocus(Qt.TabFocusReason);
                                                    keysFlick.ensureItemVisible(item);
                                                    item = item2;
                                                }
                                            }
                                            event.accepted = true;
                                        }
                                        break;
                                    case Qt.Key_Return:
                                        if (visualFocus) {
                                            toggle();
                                            toggled();
                                        }
                                        event.accepted = true;
                                        break;
                                }
                            }
                        }
                        CheckBox {
                            text: qsTr("Enable Mouse Touchpad")
                            checked: {
                                Chiaki.settings.mouseTouchEnabled
                            }
                            onToggled: Chiaki.settings.mouseTouchEnabled = checked
                            Layout.alignment: Qt.AlignRight
                            property bool firstInFocusChain: false
                            property bool lastInFocusChain: false
                            Material.roundedScale: Material.SmallScale
                            Material.background: visualFocus ? Material.accent : undefined
                            onActiveFocusChanged: if (activeFocus) keysFlick.ensureItemVisible(this)

                            Component.onDestruction: {
                                if (visualFocus) {
                                    let item = nextItemInFocusChain();
                                    if (item)
                                        item.forceActiveFocus(Qt.TabFocusReason);
                                }
                            }
                            Keys.onPressed: (event) => {
                                switch (event.key) {
                                    case Qt.Key_Left:
                                        if (!firstInFocusChain) {
                                            let item = nextItemInFocusChain(false);
                                            if (item) {
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                                keysFlick.ensureItemVisible(item);
                                            }
                                            event.accepted = true;
                                        }
                                        break;
                                    case Qt.Key_Down:
                                        if (!lastInFocusChain) {
                                            let item = nextItemInFocusChain();
                                            if (item) {
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                                keysFlick.ensureItemVisible(item);
                                            }
                                            for(var i = 0; i < 3; i++)
                                            {
                                                let item2 = item.nextItemInFocusChain();
                                                if (item)
                                                {
                                                    item.forceActiveFocus(Qt.TabFocusReason);
                                                    keysFlick.ensureItemVisible(item);
                                                    item = item2;
                                                }
                                            }
                                            event.accepted = true;
                                        }
                                        break;
                                    case Qt.Key_Return:
                                        if (visualFocus) {
                                            toggle();
                                            toggled();
                                        }
                                        event.accepted = true;
                                        break;
                                }
                            }
                        }
                        Repeater {
                            id: chiakiKeys
                            model: Chiaki.settings.controllerMapping

                            RowLayout {
                                spacing: 20

                                Label {
                                    Layout.preferredWidth: 200
                                    horizontalAlignment: Text.AlignRight
                                    text: modelData.buttonName
                                }

                                Button {
                                    property bool firstInFocusChain: false
                                    property bool lastInFocusChain: index == (chiakiKeys.count - 1)
                                    Layout.preferredWidth: 170
                                    Layout.preferredHeight: 52
                                    text: modelData.keyName
                                    Material.roundedScale: Material.SmallScale
                                    Material.background: visualFocus ? Material.accent : undefined
                                    onActiveFocusChanged: if (activeFocus) keysFlick.ensureItemVisible(this)
                                    Component.onDestruction: {
                                        if (visualFocus) {
                                            let item = nextItemInFocusChain();
                                            if (item)
                                                item.forceActiveFocus(Qt.TabFocusReason);
                                        }
                                    }
                                    onClicked: {
                                        keyDialog.show({
                                            value: modelData.buttonValue,
                                            mappingIndex: index,
                                            callback: (name) => text = name,
                                        });
                                    }
                                    Keys.onPressed: (event) => {
                                        switch (event.key) {
                                            case Qt.Key_Left:
                                                if (!firstInFocusChain && ((index % 3) != 0)) {
                                                    let item = nextItemInFocusChain(false);
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        keysFlick.ensureItemVisible(item);
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Right:
                                                if  (!lastInFocusChain && (index % 3) != 2) {
                                                    let item = nextItemInFocusChain();
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        keysFlick.ensureItemVisible(item);
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Up:
                                                if (!firstInFocusChain)
                                                {
                                                    let item = nextItemInFocusChain(false);
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        keysFlick.ensureItemVisible(item);
                                                    }
                                                    for(var i = 0; i < 3; i++)
                                                    {
                                                        let item2 = item.nextItemInFocusChain(false);
                                                        if (item)
                                                        {
                                                            item.forceActiveFocus(Qt.TabFocusReason);
                                                            keysFlick.ensureItemVisible(item);
                                                            item = item2;
                                                        }
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Down:
                                                if (!lastInFocusChain && index < (chiakiKeys.count - 3)) {
                                                    let item = nextItemInFocusChain();
                                                    if (item) {
                                                        item.forceActiveFocus(Qt.TabFocusReason);
                                                        keysFlick.ensureItemVisible(item);
                                                    }
                                                    for(var i = 0; i < 3; i++)
                                                    {
                                                        let item2 = item.nextItemInFocusChain();
                                                        if (item)
                                                        {
                                                            item.forceActiveFocus(Qt.TabFocusReason);
                                                            keysFlick.ensureItemVisible(item);
                                                            item = item2;
                                                        }
                                                    }
                                                    event.accepted = true;
                                                }
                                                break;
                                            case Qt.Key_Return:
                                                if (visualFocus) {
                                                    clicked();
                                                }
                                                break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Item {
                // Controllers
                Flickable {
                    id: controllersFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, controllersLayout.width + 140)
                    contentHeight: controllersLayout.y + controllersLayout.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        id: controllersScrollbar
                        policy: ScrollBar.AlwaysOn
                        visible: controllersFlick.contentHeight > controllersFlick.height
                    }
                    Rectangle {
                        x: controllersLayout.x - 32
                        y: controllersLayout.y - 28
                        width: controllersLayout.width + 64
                        height: controllersLayout.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: controllersLayout.x - 32
                        y: 14
                        text: qsTr("Controllers")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: controllersLayout.x - 32
                        y: 66
                        text: qsTr("Button mapping and controller behaviour.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    ColumnLayout {
                        id: controllersLayout
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        spacing: 10
                        C.Button {
                            Layout.alignment: Qt.AlignHCenter
                            id: controllerMappingChange
                            firstInFocusChain: true
                            text: qsTr("Change Controller Mapping")
                            onClicked: controllerMappingDialog.show({
                                reset: false
                            });
                        }
                        C.Button {
                            Layout.alignment: Qt.AlignHCenter
                            id: controllerMappingReset
                            text: qsTr("Reset Controller Mapping")
                            onClicked: controllerMappingDialog.show({
                                reset: true
                            });
                        }

                        RowLayout {
                            spacing: 10
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Background Controller Events:")
                            }
                            C.CheckBox {
                                id: backgroundController
                                text: qsTr("Process controller input when application is in background")
                                checked: {
                                    Chiaki.settings.allowJoystickBackgroundEvents
                                }
                                onToggled: Chiaki.settings.allowJoystickBackgroundEvents = checked
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(On)")
                            }
                        }
                        RowLayout {
                            spacing: 10
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Dpad Touchpad Emulation")
                            }
                            C.CheckBox {
                                id: dpadTouch
                                checked: Chiaki.settings.dpadTouchEnabled
                                onToggled: Chiaki.settings.dpadTouchEnabled = !Chiaki.settings.dpadTouchEnabled
                                KeyNavigation.priority: KeyNavigation.BeforeItem
                                KeyNavigation.up: backgroundController
                                KeyNavigation.left: dpadTouch
                                KeyNavigation.right: dpadTouch
                                KeyNavigation.down: {
                                    if(touchIncrement.visible)
                                        touchIncrement
                                    else
                                        posButtons
                                }
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(On)")
                            }
                        }

                        RowLayout {
                            id: touchIncrementLayout
                            spacing: 10
                            Layout.alignment: Qt.AlignHCenter
                            visible: Chiaki.settings.dpadTouchEnabled
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Dpad Touch Increment:")
                            }

                            C.Slider {
                                id: touchIncrement
                                Layout.preferredWidth: 250
                                from: 1
                                to: 1079
                                stepSize: 1
                                value: Chiaki.settings.dpadTouchIncrement
                                onMoved: Chiaki.settings.dpadTouchIncrement = value

                                Label {
                                    anchors {
                                        left: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: 10
                                    }
                                    text: qsTr("%1 mm").arg(parent.value / 100)
                                }
                                KeyNavigation.priority: KeyNavigation.BeforeItem
                                KeyNavigation.up: dpadTouch
                                KeyNavigation.down: {
                                    if(dpadShortcut1.visible)
                                        dpadShortcut1
                                    else
                                        posButtons;
                                }
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                Layout.leftMargin: 100
                                text: qsTr("(0.3 mm)")
                            }
                        }
                        RowLayout {
                            spacing: 10
                            visible: Chiaki.settings.dpadTouchEnabled
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Dpad Regular/Touch Combo:")
                            }

                            C.ComboBox {
                                id: dpadShortcut1
                                implicitContentWidthPolicy: ComboBox.WidestText
                                firstInFocusChain: false
                                model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                                currentIndex: Chiaki.settings.dpadTouchShortcut1
                                onActivated: index => Chiaki.settings.dpadTouchShortcut1 = index
                                KeyNavigation.priority: {
                                    if(!popup.visible)
                                        KeyNavigation.BeforeItem
                                    else
                                        KeyNavigation.AfterItem
                                }
                                KeyNavigation.up: touchIncrement
                                KeyNavigation.down: posButtons
                                KeyNavigation.left: dpadShortcut1
                                KeyNavigation.right: dpadShortcut2
                            }

                            C.ComboBox {
                                id: dpadShortcut2
                                implicitContentWidthPolicy: ComboBox.WidestText
                                firstInFocusChain: false
                                model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                                currentIndex: Chiaki.settings.dpadTouchShortcut2
                                onActivated: index => Chiaki.settings.dpadTouchShortcut2 = index
                                KeyNavigation.priority: {
                                    if(!popup.visible)
                                        KeyNavigation.BeforeItem
                                    else
                                        KeyNavigation.AfterItem
                                }
                                KeyNavigation.up: touchIncrement
                                KeyNavigation.down: posButtons
                                KeyNavigation.left: dpadShortcut1
                                KeyNavigation.right: dpadShortcut3
                            }

                            C.ComboBox {
                                id: dpadShortcut3
                                implicitContentWidthPolicy: ComboBox.WidestText
                                firstInFocusChain: false
                                model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                                currentIndex: Chiaki.settings.dpadTouchShortcut3
                                onActivated: index => Chiaki.settings.dpadTouchShortcut3 = index
                                KeyNavigation.priority: {
                                    if(!popup.visible)
                                        KeyNavigation.BeforeItem
                                    else
                                        KeyNavigation.AfterItem
                                }
                                KeyNavigation.up: touchIncrement
                                KeyNavigation.down: posButtons
                                KeyNavigation.left: dpadShortcut2
                                KeyNavigation.right: dpadShortcut4
                            }

                            C.ComboBox {
                                id: dpadShortcut4
                                implicitContentWidthPolicy: ComboBox.WidestText
                                firstInFocusChain: false
                                model: [qsTr("Not Used"), qsTr("Cross"), qsTr("Moon"), qsTr("Box"), qsTr("Pyramid"), qsTr("Dpad Left"), qsTr("Dpad Right"), qsTr("Dpad Up"), qsTr("Dpad Down"), qsTr("L1"), qsTr("R1"), qsTr("L3"), qsTr("R3"), qsTr("Options"), qsTr("Share"), qsTr("Touchpad"), qsTr("PS")]
                                currentIndex: Chiaki.settings.dpadTouchShortcut4
                                onActivated: index => Chiaki.settings.dpadTouchShortcut4 = index
                                KeyNavigation.priority: {
                                    if(!popup.visible)
                                        KeyNavigation.BeforeItem
                                    else
                                        KeyNavigation.AfterItem
                                }
                                KeyNavigation.up: touchIncrement
                                KeyNavigation.down: posButtons
                                KeyNavigation.left: dpadShortcut3
                                KeyNavigation.right: dpadShortcut4
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(L1+R1+dpad Up)")
                            }
                        }
                        RowLayout {
                            spacing: 10
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Buttons By Position:")
                            }

                            C.CheckBox {
                                id: posButtons
                                text: qsTr("Use buttons by position instead of by label")
                                checked: Chiaki.settings.buttonsByPosition
                                onToggled: Chiaki.settings.buttonsByPosition = checked
                                KeyNavigation.priority: KeyNavigation.BeforeItem
                                KeyNavigation.up: {
                                    if(dpadShortcut1.visible)
                                        dpadShortcut1
                                    else
                                        dpadTouch;
                                }
                                KeyNavigation.down: rumbleHaptics
                                KeyNavigation.left: posButtons
                                KeyNavigation.right: posButtons
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(Off)")
                            }
                        }
                        RowLayout {
                            spacing: 10
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("Rumble Haptics:")
                            }

                            C.ComboBox {
                                id: rumbleHaptics
                                Layout.preferredWidth: 400
                                model: [qsTr("Off"), qsTr("Very Weak"), qsTr("Weak"), qsTr("Normal"), qsTr("Strong"), qsTr("Very Strong")]
                                currentIndex: Chiaki.settings.rumbleHapticsIntensity
                                onActivated: (index) => Chiaki.settings.rumbleHapticsIntensity = index;
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                color: "#A08F84"
                                font.pixelSize: 14
                                text: qsTr("(Normal)")
                            }
                        }
                        RowLayout {
                            spacing: 10
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                Layout.alignment: Qt.AlignLeft
                                text: qsTr("True Haptics Intensity:")
                            }

                            C.Slider {
                                id: hapticOverride
                                Layout.preferredWidth: 250
                                from: 0
                                to: 2
                                stepSize: 0.1
                                value: Chiaki.settings.hapticOverride
                                onMoved: Chiaki.settings.hapticOverride = value;
                                lastInFocusChain: true
                                Label {
                                    anchors {
                                        left: parent.right
                                        verticalCenter: parent.verticalCenter
                                        leftMargin: 10
                                    }
                                    text: {
                                        if(parent.value > 0.99 && parent.value < 1.01)
                                            qsTr("console setting")
                                        else
                                            (parent.value * 100).toFixed(0) + qsTr(" % console setting")
                                    }
                                }
                            }

                            Label {
                                Layout.alignment: Qt.AlignLeft
                                Layout.leftMargin: 250
                                text: qsTr("(console setting)")
                            }
                        }
                    }
                }
            }

            Item {
                // Remote (PSN and Hole Punching)
                Flickable {
                    id: remoteFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, remoteGrid.width + 140)
                    contentHeight: remoteGrid.y + remoteGrid.height + 60
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: remoteFlick.contentHeight > remoteFlick.height
                    }
                    Rectangle {
                        x: remoteGrid.x - 32
                        y: remoteGrid.y - 28
                        width: remoteGrid.width + 64
                        height: remoteGrid.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: remoteGrid.x - 32
                        y: 14
                        text: qsTr("Remote play")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: remoteGrid.x - 32
                        y: 66
                        text: qsTr("PSN sign-in, for playing away from home.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    GridLayout {
                        id: remoteGrid
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        columns: 3
                        rowSpacing: 20
                        columnSpacing: 10

                        C.Button {
                            id: openPsnLogin
                            firstInFocusChain: visible
                            Layout.alignment: Qt.AlignHCenter
                            Layout.columnSpan: 3

                            text: qsTr("Login to PSN")
                            onClicked: {
                                root.showPSNTokenDialog(false)
                            }
                            Material.roundedScale: Material.SmallScale
                            visible: !Chiaki.settings.psnRefreshToken || !Chiaki.settings.psnAuthToken || !Chiaki.settings.psnAuthTokenExpiry || !Chiaki.settings.psnAccountId
                        }

                        C.Button {
                            id: resetPsnTokens
                            topPadding: 26
                            leftPadding: 30
                            rightPadding: 30
                            bottomPadding: 26
                            text: qsTr("Clear PSN Token")
                            firstInFocusChain: !openPsnLogin.visible
                            Layout.alignment: Qt.AlignHCenter
                            Layout.columnSpan: 3
                            onClicked: {
                                Chiaki.settings.psnRefreshToken = ""
                                Chiaki.settings.psnAuthToken = ""
                                Chiaki.settings.psnAuthTokenExpiry = ""
                                Chiaki.settings.psnAccountId = ""
                                openPsnLogin.forceActiveFocus(Qt.TabFocusReason);
                            }
                            Material.roundedScale: Material.SmallScale
                            visible: Chiaki.settings.psnRefreshToken && Chiaki.settings.psnAuthToken && Chiaki.settings.psnAuthTokenExpiry && Chiaki.settings.psnAccountId
                        }


                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Hole Punching Port Guessing:")
                        }

                        C.CheckBox {
                            id: holePunchGuessingCheckbox
                            text: qsTr("Force STUN port guessing")
                            checked: Chiaki.settings.portGuessingEnabled
                            onToggled: Chiaki.settings.portGuessingEnabled = checked
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(Off)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Port Guess Count:")
                        }

                        C.Slider {
                            id: portGuessCountSlider
                            Layout.preferredWidth: 250
                            from: 0
                            to: 75
                            stepSize: 1
                            value: Chiaki.settings.portGuessCount
                            onMoved: Chiaki.settings.portGuessCount = value

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: parent.value + qsTr(" guesses")
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            Layout.leftMargin: 100
                            text: qsTr("(75)")
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            text: qsTr("Port Guess Socket Count:")
                        }

                        C.Slider {
                            id: portGuessSocketSlider
                            Layout.preferredWidth: 250
                            from: 0
                            to: 500
                            stepSize: 1
                            value: Chiaki.settings.portGuessSocketCount
                            onMoved: Chiaki.settings.portGuessSocketCount = value
                            lastInFocusChain: true

                            Label {
                                anchors {
                                    left: parent.right
                                    verticalCenter: parent.verticalCenter
                                    leftMargin: 10
                                }
                                text: parent.value + qsTr(" sockets")
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignLeft
                            color: "#A08F84"
                            font.pixelSize: 14
                            text: qsTr("(250)")
                            Layout.leftMargin: 100
                        }
                    }
                }
            }

            Item {
                // Config (Options such as Import/Export and Logging)
                Flickable {
                    id: configFlick
                    anchors {
                        fill: parent
                        topMargin: 20
                        bottomMargin: 20
                    }
                    clip: true
                    contentWidth: Math.max(width, configGrid.width + 140)
                    contentHeight: resetCard.y + resetCard.height + 40
                    flickableDirection: Flickable.AutoFlickIfNeeded
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AlwaysOn
                        visible: configFlick.contentHeight > configFlick.height
                    }
                    Rectangle {
                        x: configGrid.x - 32
                        y: configGrid.y - 28
                        width: configGrid.width + 64
                        height: configGrid.height + 56
                        radius: 16
                        color: "#1D1816"
                        border.color: "#3B302B"
                    }
                    Label {
                        x: configGrid.x - 32
                        y: 14
                        text: qsTr("Profiles and data")
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 36
                        color: "#FBF4EC"
                    }
                    Label {
                        x: configGrid.x - 32
                        y: 66
                        text: qsTr("Profiles, import and export, logs and about.")
                        font.pixelSize: 15
                        color: "#CDBFB4"
                    }
                    GridLayout {
                        id: configGrid
                        anchors {
                            top: parent.top
                            left: parent.left
                            topMargin: 132
                            leftMargin: 78
                        }
                        columns: 1
                        rowSpacing: 20
                        columnSpacing: 10

                        Label {
                            text: {
                                if(Chiaki.settings.currentProfile)
                                    qsTr("Current Profile: ") + Chiaki.settings.currentProfile
                                else
                                    qsTr("Current Profile: default")
                            }
                        }

                        C.Button {
                            id: profile
                            firstInFocusChain: true
                            text: qsTr("Manage Profiles")
                            onClicked: {
                                root.showProfileDialog()
                            }
                            Material.roundedScale: Material.SmallScale
                        }

                    C.Button {
                        id: exportButton
                        text: qsTr("Export settings to file")
                        onClicked: {
                            Chiaki.settings.exportSettings();
                        }
                        Material.roundedScale: Material.SmallScale
                    }

                    C.Button {
                        id: importButton
                        text: qsTr("Import settings from file")
                        onClicked: {
                            Chiaki.settings.importSettings();
                        }
                        Material.roundedScale: Material.SmallScale
                    }

                    C.Button {
                        id: aboutButton
                        text: qsTr("About Robz Play")
                        onClicked: aboutDialog.open()
                        Material.roundedScale: Material.SmallScale
                    }

                    C.CheckBox {
                        text: qsTr("Sanitize Logs (checked)")
                        checked: Chiaki.settings.logSanitize
                        onToggled: Chiaki.settings.logSanitize = checked
                    }

                        C.CheckBox {
                            text: qsTr("Verbose Logging (unchecked)")
                            checked: Chiaki.settings.logVerbose
                            onToggled: Chiaki.settings.logVerbose = checked
                        }
                    }

                    // Robz Play: back to how it was on the first start, after a warning
                    Rectangle {
                        id: resetCard
                        x: configGrid.x - 32
                        y: configGrid.y + configGrid.height + 52
                        width: Math.max(configGrid.width + 64, 640)
                        height: resetColumn.implicitHeight + 48
                        radius: 16
                        color: "#211715"
                        border.color: "#6B3A2C"

                        ColumnLayout {
                            id: resetColumn
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: 24
                            }
                            spacing: 10
                            Label {
                                text: qsTr("Reset to factory settings")
                                color: "#FBF4EC"
                                font.family: "Segoe UI"
                                font.weight: Font.Black
                                font.italic: true
                                font.pixelSize: 22
                            }
                            Label {
                                Layout.fillWidth: true
                                text: qsTr("Robz Play goes back to how it was on its first start: the registered consoles, the PSN sign-in, every setting and profile, the key mappings and the logs are removed.")
                                color: "#CDBFB4"
                                font.pixelSize: 15
                                wrapMode: Text.Wrap
                            }
                            C.Button {
                                id: factoryResetButton
                                Layout.topMargin: 6
                                lastInFocusChain: true
                                text: qsTr("Reset to factory settings…")
                                Material.background: visualFocus ? "#C8553D" : "#8E3B2A"
                                Material.foreground: "#FBF4EC"
                                Material.roundedScale: Material.SmallScale
                                onClicked: factoryResetDialog.open()
                            }
                        }
                    }
                }
            }

            // Robz Play: the log files, listed and shown here, for when something goes wrong
            Item {
                id: logsPage
                property var files: []
                property string selected: ""
                property string text: ""
                property bool truncated: false
                property bool onlyProblems: false
                // streamer mode: a log can hold the console's address, so it is shown only on request
                property bool revealed: false
                property bool copied: false
                readonly property bool hiddenByStreamerMode: Chiaki.settings.streamerMode && !revealed
                readonly property var problemLine: /\] \[(W|E)\] |\[(uyarı|HATA|ÖLÜMCÜL HATA)\]|ÇÖKTÜ/
                readonly property string shownText: onlyProblems
                    ? text.split("\n").filter(line => problemLine.test(line)).join("\n")
                    : text
                // search (Ctrl+F): where the query occurs in the text shown, and which one is selected
                property string query: ""
                property var matches: []
                property int matchIndex: -1
                onShownTextChanged: { findMatches(); Qt.callLater(scrollToEnd); }
                onQueryChanged: findMatches()

                function findMatches() {
                    const found = [];
                    const q = query.toLowerCase();
                    if (q.length > 0) {
                        const hay = shownText.toLowerCase();
                        let at = hay.indexOf(q);
                        while (at >= 0 && found.length < 10000) {
                            found.push(at);
                            at = hay.indexOf(q, at + q.length);
                        }
                    }
                    matches = found;
                    matchIndex = -1;
                    if (found.length)
                        showMatch(0);
                    else
                        logArea.deselect();
                }
                function showMatch(i) {
                    if (!matches.length)
                        return;
                    matchIndex = (i + matches.length) % matches.length;
                    const start = matches[matchIndex];
                    logArea.select(start, start + query.length);
                    const r = logArea.positionToRectangle(start);
                    logFlick.contentY = Math.max(0, Math.min(logFlick.contentHeight - logFlick.height, r.y - logFlick.height / 2));
                    logFlick.contentX = Math.max(0, Math.min(logFlick.contentWidth - logFlick.width, r.x - logFlick.width / 3));
                }
                function scrollToEnd() {
                    if (matches.length)
                        return;
                    logFlick.contentX = 0;
                    logFlick.contentY = Math.max(0, logFlick.contentHeight - logFlick.height);
                }
                function scrollBy(dy) {
                    logFlick.contentY = Math.max(0, Math.min(Math.max(0, logFlick.contentHeight - logFlick.height), logFlick.contentY + dy));
                }
                function openSearch() {
                    searchField.forceActiveFocus(Qt.ShortcutFocusReason);
                    searchField.selectAll();
                }

                Shortcut {
                    sequences: [StandardKey.Find]
                    enabled: logsPage.visible
                    onActivated: logsPage.openSearch()
                }

                function refresh() {
                    files = Chiaki.settings.logFiles();
                    let keep = files.some(f => f.name === selected);
                    // the latest stream is what a problem is usually about
                    const latestStream = files.find(f => f.kind === "session");
                    showFile(keep ? selected : (latestStream ? latestStream.name : (files.length ? files[0].name : "")));
                }
                function showFile(name) {
                    selected = name;
                    copied = false;
                    if (!name) {
                        text = "";
                        truncated = false;
                        return;
                    }
                    const result = Chiaki.settings.readLogFile(name);
                    text = result.text;
                    truncated = result.truncated;
                }
                function kindName(kind) {
                    switch (kind) {
                    case "startup": return qsTr("This start");
                    case "previous": return qsTr("Previous start");
                    case "session": return qsTr("Stream");
                    default: return qsTr("Other");
                    }
                }
                function sizeText(bytes) {
                    return bytes >= 1048576 ? qsTr("%1 MB").arg((bytes / 1048576).toFixed(1))
                                            : qsTr("%1 KB").arg(Math.max(1, Math.round(bytes / 1024)));
                }
                onVisibleChanged: if (visible) refresh()

                // copies the text shown, without showing a selection
                TextEdit {
                    id: clipboardHelper
                    visible: false
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 30
                    spacing: 14

                    Label {
                        text: qsTr("Logs")
                        color: "#FBF4EC"
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 30
                    }
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Robz Play writes every start and every stream into a log file. When something goes wrong - for example the picture stays black after Play and you are taken back to the home screen - the log of that stream says why. Ask for help on Discord with that log or with the diagnostics file.")
                        color: "#CDBFB4"
                        font.pixelSize: 15
                        wrapMode: Text.Wrap
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: 10
                        C.Button {
                            id: logOpenFolderButton
                            text: qsTr("Open log folder")
                            onClicked: Chiaki.settings.openLogFolder()
                            KeyNavigation.right: logOpenFileButton
                        }
                        C.Button {
                            id: logOpenFileButton
                            text: qsTr("Open in text editor")
                            enabled: logsPage.selected.length > 0
                            onClicked: Chiaki.settings.openLogFile(logsPage.selected)
                            KeyNavigation.left: logOpenFolderButton
                            KeyNavigation.right: logCopyButton
                        }
                        C.Button {
                            id: logCopyButton
                            text: logsPage.copied ? qsTr("Copied") : qsTr("Copy")
                            enabled: logsPage.shownText.length > 0 && !logsPage.hiddenByStreamerMode
                            onClicked: {
                                clipboardHelper.text = logsPage.shownText;
                                clipboardHelper.selectAll();
                                clipboardHelper.copy();
                                clipboardHelper.text = "";
                                logsPage.copied = true;
                            }
                            KeyNavigation.left: logOpenFileButton
                            KeyNavigation.right: logDiagnosticsButton.visible ? logDiagnosticsButton : logRefreshButton
                        }
                        C.Button {
                            id: logDiagnosticsButton
                            text: qsTr("Create diagnostics file")
                            visible: Chiaki.settings.diagnosticsAvailable()
                            onClicked: Chiaki.settings.runDiagnostics()
                            KeyNavigation.left: logCopyButton
                            KeyNavigation.right: logRefreshButton
                        }
                        C.Button {
                            id: logRefreshButton
                            text: qsTr("Refresh")
                            onClicked: logsPage.refresh()
                            KeyNavigation.left: logDiagnosticsButton.visible ? logDiagnosticsButton : logCopyButton
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 14

                        // the files, newest first
                        Rectangle {
                            Layout.preferredWidth: 300
                            Layout.fillHeight: true
                            radius: 12
                            color: "#171312"
                            border.color: "#3B302B"
                            ListView {
                                id: logList
                                anchors.fill: parent
                                anchors.margins: 6
                                clip: true
                                spacing: 4
                                model: logsPage.files
                                ScrollBar.vertical: ScrollBar {}
                                delegate: AbstractButton {
                                    id: logEntry
                                    required property var modelData
                                    readonly property bool current: logsPage.selected === modelData.name
                                    width: logList.width - 10
                                    height: 58
                                    hoverEnabled: true
                                    focusPolicy: Qt.NoFocus
                                    onClicked: logsPage.showFile(modelData.name)
                                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                                    background: Rectangle {
                                        radius: 9
                                        color: logEntry.current ? "#271F1C" : (logEntry.hovered ? "#1C1715" : "transparent")
                                        border.width: logEntry.current ? 1 : 0
                                        border.color: "#E4845E"
                                    }
                                    contentItem: ColumnLayout {
                                        spacing: 2
                                        RowLayout {
                                            Layout.leftMargin: 12
                                            Layout.rightMargin: 10
                                            spacing: 8
                                            Label {
                                                text: logsPage.kindName(logEntry.modelData.kind)
                                                color: "#FBF4EC"
                                                font.pixelSize: 15
                                                font.bold: logEntry.current
                                            }
                                            Rectangle {
                                                visible: logEntry.modelData.problems
                                                radius: 5
                                                color: "#3A2A1C"
                                                implicitWidth: problemLabel.implicitWidth + 12
                                                implicitHeight: problemLabel.implicitHeight + 4
                                                Label {
                                                    id: problemLabel
                                                    anchors.centerIn: parent
                                                    text: qsTr("has errors")
                                                    color: "#D9A65A"
                                                    font.pixelSize: 11
                                                }
                                            }
                                            Item { Layout.fillWidth: true }
                                        }
                                        Label {
                                            Layout.leftMargin: 12
                                            text: "%1 · %2".arg(logEntry.modelData.modified).arg(logsPage.sizeText(logEntry.modelData.size))
                                            color: "#A08F84"
                                            font.pixelSize: 12
                                        }
                                    }
                                }
                                Label {
                                    anchors.centerIn: parent
                                    visible: logList.count === 0
                                    text: qsTr("No log files yet")
                                    color: "#A08F84"
                                }
                            }
                        }

                        // the chosen file
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Label {
                                    Layout.fillWidth: true
                                    text: logsPage.selected
                                    color: "#CDBFB4"
                                    font.pixelSize: 13
                                    elide: Text.ElideMiddle
                                }
                                C.CheckBox {
                                    id: logProblemsOnly
                                    checked: logsPage.onlyProblems
                                    onToggled: logsPage.onlyProblems = checked
                                }
                                Label {
                                    text: qsTr("Only warnings and errors")
                                    color: "#CDBFB4"
                                    font.pixelSize: 13
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                visible: !logsPage.hiddenByStreamerMode
                                // a plain box: the text field's floating hint would sit on its border
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 40
                                    radius: 10
                                    color: "#171312"
                                    border.width: searchField.activeFocus ? 2 : 1
                                    border.color: searchField.activeFocus ? "#E4845E" : "#3B302B"
                                    TextInput {
                                        id: searchField
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        color: "#FBF4EC"
                                        font.pixelSize: 14
                                        selectByMouse: true
                                        selectionColor: "#E4845E"
                                        selectedTextColor: "#141110"
                                        onTextChanged: logsPage.query = text
                                        Keys.onReturnPressed: (event) => logsPage.showMatch(logsPage.matchIndex + ((event.modifiers & Qt.ShiftModifier) ? -1 : 1))
                                        Keys.onEnterPressed: (event) => logsPage.showMatch(logsPage.matchIndex + ((event.modifiers & Qt.ShiftModifier) ? -1 : 1))
                                        Keys.onEscapePressed: (event) => {
                                            if (text.length) {
                                                text = "";
                                                event.accepted = true;
                                            } else {
                                                event.accepted = false;
                                            }
                                        }
                                    }
                                    Label {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: searchField.text.length === 0
                                        text: qsTr("Search the log (Ctrl+F)")
                                        color: "#A08F84"
                                        font.pixelSize: 14
                                    }
                                }
                                Label {
                                    visible: logsPage.query.length > 0
                                    text: logsPage.matches.length ? qsTr("%1 / %2").arg(logsPage.matchIndex + 1).arg(logsPage.matches.length) : qsTr("not found")
                                    color: logsPage.matches.length ? "#CDBFB4" : "#D9A65A"
                                    font.pixelSize: 13
                                }
                                C.Button {
                                    text: "↑"
                                    enabled: logsPage.matches.length > 0
                                    onClicked: logsPage.showMatch(logsPage.matchIndex - 1)
                                    ToolTip.visible: hovered
                                    ToolTip.text: qsTr("Previous (Shift+Enter)")
                                }
                                C.Button {
                                    text: "↓"
                                    enabled: logsPage.matches.length > 0
                                    onClicked: logsPage.showMatch(logsPage.matchIndex + 1)
                                    ToolTip.visible: hovered
                                    ToolTip.text: qsTr("Next (Enter)")
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                radius: 12
                                color: "#0F0C0B"
                                border.color: "#3B302B"
                                Flickable {
                                    id: logFlick
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    visible: !logsPage.hiddenByStreamerMode
                                    clip: true
                                    contentWidth: logArea.width
                                    contentHeight: logArea.height
                                    boundsBehavior: Flickable.StopAtBounds
                                    flickableDirection: Flickable.AutoFlickIfNeeded
                                    ScrollBar.vertical: ScrollBar {
                                        policy: logFlick.contentHeight > logFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
                                        minimumSize: 0.05
                                    }
                                    ScrollBar.horizontal: ScrollBar {
                                        policy: logFlick.contentWidth > logFlick.width ? ScrollBar.AlwaysOn : ScrollBar.AsNeeded
                                    }
                                    // a wheel always scrolls the log, whatever the text under it does with it
                                    WheelHandler {
                                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                        onWheel: (event) => {
                                            if (event.modifiers & Qt.ShiftModifier)
                                                logFlick.contentX = Math.max(0, Math.min(Math.max(0, logFlick.contentWidth - logFlick.width), logFlick.contentX - event.angleDelta.y));
                                            else
                                                logsPage.scrollBy(-event.angleDelta.y / 120 * 3 * 17);
                                        }
                                    }

                                    TextEdit {
                                        id: logArea
                                        width: Math.max(implicitWidth, logFlick.width - 14)
                                        height: Math.max(implicitHeight, logFlick.height)
                                        leftPadding: 8
                                        topPadding: 6
                                        bottomPadding: 6
                                        rightPadding: 8
                                        readOnly: true
                                        selectByMouse: true
                                        persistentSelection: true
                                        textFormat: TextEdit.PlainText
                                        wrapMode: TextEdit.NoWrap
                                        text: logsPage.shownText
                                        color: "#CDBFB4"
                                        selectionColor: "#E4845E"
                                        selectedTextColor: "#141110"
                                        font.family: "Consolas"
                                        font.pixelSize: 12
                                        // reading with the keyboard
                                        Keys.onPressed: (event) => {
                                            const line = 17;
                                            switch (event.key) {
                                            case Qt.Key_Up: logsPage.scrollBy(-line * 2); break;
                                            case Qt.Key_Down: logsPage.scrollBy(line * 2); break;
                                            case Qt.Key_PageUp: logsPage.scrollBy(-logFlick.height * 0.9); break;
                                            case Qt.Key_PageDown: logsPage.scrollBy(logFlick.height * 0.9); break;
                                            case Qt.Key_Home: logFlick.contentY = 0; break;
                                            case Qt.Key_End: logsPage.scrollBy(logFlick.contentHeight); break;
                                            default: return;
                                            }
                                            event.accepted = true;
                                        }
                                    }
                                    Label {
                                        visible: logsPage.onlyProblems && logsPage.shownText.length === 0 && logsPage.text.length > 0
                                        anchors.centerIn: parent
                                        text: qsTr("No warnings or errors in this log")
                                        color: "#A08F84"
                                    }
                                }
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    width: Math.min(parent.width - 40, 460)
                                    visible: logsPage.hiddenByStreamerMode
                                    spacing: 12
                                    Label {
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignHCenter
                                        text: qsTr("Streamer mode is on. A log can contain your console's address, so it is not shown on screen.")
                                        color: "#CDBFB4"
                                        font.pixelSize: 14
                                        wrapMode: Text.Wrap
                                    }
                                    C.Button {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: qsTr("Show anyway")
                                        onClicked: logsPage.revealed = true
                                    }
                                }
                            }
                            Label {
                                Layout.fillWidth: true
                                visible: logsPage.truncated
                                text: qsTr("The file is long: its last part is shown. Open it in a text editor for all of it.")
                                color: "#A08F84"
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }
            }
        }

        Connections {
            target: dialog.Window.window
            function onActiveFocusItemChanged() {
                dialog.ensureActiveFocusVisible()
            }
        }

        Item {
            Timer {
                id: openTimer
                interval: 100
                running: false
                onTriggered: {
                    if(controllerMappingDialog.resetMapping)
                    {
                        if(!Chiaki.controllerMappingDefaultMapping)
                        {
                            quitControllerMapping = false;
                            Chiaki.controllerMappingReset();
                        }
                        controllerMappingDialog.close();
                    }
                    else
                    {
                        controllerMappingChange.forceActiveFocus(Qt.TabFocusReason);
                        root.showControllerMappingDialog();
                        quitControllerMapping = false;
                        controllerMappingDialog.resetFocus = false;
                        controllerMappingDialog.close();
                    }
                }
            }
        }

        // Robz Play: the warning before a factory reset. Nothing is removed until the red button;
        // the focus starts on Cancel.
        Dialog {
            id: factoryResetDialog
            parent: Overlay.overlay
            x: Math.round((root.width - width) / 2)
            y: Math.round((root.height - height) / 2)
            width: Math.min(680, root.width - 64)
            modal: true
            focus: true
            closePolicy: working ? Popup.NoAutoClose : Popup.CloseOnEscape
            header: null
            footer: null
            padding: 32
            property bool working: false
            property bool failed: false
            onOpened: {
                working = false;
                failed = false;
                resetCancelButton.forceActiveFocus(Qt.TabFocusReason);
            }
            onClosed: factoryResetButton.forceActiveFocus(Qt.TabFocusReason)
            Overlay.modal: Rectangle { color: "#B30C0A09" }
            background: Rectangle {
                radius: 18
                color: "#1D1816"
                border.width: 2
                border.color: "#8E3B2A"
            }

            contentItem: ColumnLayout {
                spacing: 16

                RowLayout {
                    spacing: 14
                    Rectangle {
                        implicitWidth: 40
                        implicitHeight: 40
                        radius: 20
                        color: "#3A1F18"
                        border.color: "#D9A65A"
                        border.width: 2
                        Label {
                            anchors.centerIn: parent
                            text: "!"
                            color: "#D9A65A"
                            font.pixelSize: 22
                            font.weight: Font.Black
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Reset Robz Play to factory settings?")
                        color: "#FBF4EC"
                        font.family: "Segoe UI"
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 26
                        wrapMode: Text.Wrap
                    }
                }

                Label {
                    Layout.fillWidth: true
                    text: qsTr("Robz Play goes back to how it was on its first start. All of this is removed from this PC for good:")
                    color: "#CDBFB4"
                    font.pixelSize: 15
                    wrapMode: Text.Wrap
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 6
                    spacing: 8
                    Repeater {
                        model: [
                            qsTr("<b>Registered and hidden consoles</b> with their pairing keys: the consoles must be registered again"),
                            qsTr("<b>The PSN sign-in</b> and the account ID"),
                            qsTr("<b>Every setting and profile</b>: picture, stream, sound, frame generation, language"),
                            qsTr("<b>Keyboard and controller mappings</b>"),
                            qsTr("<b>The logs</b>, the caches and downloaded updates")
                        ]
                        RowLayout {
                            required property string modelData
                            Layout.fillWidth: true
                            spacing: 10
                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                Layout.topMargin: 8
                                implicitWidth: 6
                                implicitHeight: 6
                                radius: 1
                                color: "#E4845E"
                            }
                            Label {
                                Layout.fillWidth: true
                                text: modelData
                                color: "#CDBFB4"
                                font.pixelSize: 15
                                wrapMode: Text.Wrap
                                textFormat: Text.StyledText
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: resetNote.implicitHeight + 24
                    radius: 10
                    color: "#2A1E16"
                    border.color: "#5C4426"
                    Label {
                        id: resetNote
                        anchors {
                            left: parent.left
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                            margins: 14
                        }
                        text: qsTr("<b>This cannot be undone.</b> To keep a copy of your settings, export them to a file first. Robz Play then restarts like a new installation. chiaki-ng's own settings and a shortcut added to Steam are not touched.")
                        color: "#E8C58E"
                        font.pixelSize: 14
                        wrapMode: Text.Wrap
                        textFormat: Text.StyledText
                    }
                }

                Label {
                    Layout.fillWidth: true
                    visible: factoryResetDialog.failed
                    text: qsTr("Robz Play could not be started again, so nothing was removed.")
                    color: "#D9A65A"
                    font.pixelSize: 14
                    wrapMode: Text.Wrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    spacing: 12
                    C.Button {
                        flat: true
                        font.pixelSize: 15
                        enabled: !factoryResetDialog.working
                        text: qsTr("Export settings first")
                        onClicked: Chiaki.settings.exportSettings()
                    }
                    Item { Layout.fillWidth: true }
                    C.Button {
                        id: resetCancelButton
                        firstInFocusChain: true
                        font.pixelSize: 15
                        enabled: !factoryResetDialog.working
                        text: qsTr("Cancel")
                        onClicked: factoryResetDialog.close()
                        Material.roundedScale: Material.SmallScale
                    }
                    C.Button {
                        id: resetConfirmButton
                        lastInFocusChain: true
                        font.pixelSize: 15
                        font.bold: true
                        enabled: !factoryResetDialog.working
                        text: factoryResetDialog.working ? qsTr("Restarting…") : qsTr("Remove everything and restart")
                        Material.background: visualFocus ? "#D8644A" : "#B84A32"
                        Material.foreground: "#FBF4EC"
                        Material.roundedScale: Material.SmallScale
                        onClicked: {
                            factoryResetDialog.working = true;
                            factoryResetDialog.failed = false;
                            if (Chiaki.settings.factoryReset()) {
                                Qt.quit();
                            } else {
                                factoryResetDialog.working = false;
                                factoryResetDialog.failed = true;
                            }
                        }
                    }
                }
            }
        }

        Dialog {
            id: aboutDialog
            parent: Overlay.overlay
            x: Math.round((root.width - width) / 2)
            y: Math.round((root.height - height) / 2)
            title: qsTr("About Robz Play")
            modal: true
            standardButtons: Dialog.Ok
            Material.roundedScale: Material.MediumScale
            onAboutToHide: aboutButton.forceActiveFocus(Qt.TabFocusReason)

            RowLayout {
                spacing: 50
                onVisibleChanged: if (visible) forceActiveFocus(Qt.TabFocusReason)
                Keys.onReturnPressed: aboutDialog.close()
                Keys.onEscapePressed: aboutDialog.close()

                Image {
                    Layout.preferredWidth: 200
                    fillMode: Image.PreserveAspectFit
                    verticalAlignment: Image.AlignTop
                    source: "qrc:/icons/robzplay.png"
                    sourceSize: Qt.size(200, 200)
                }

                Label {
                    Layout.preferredWidth: 400
                    verticalAlignment: Text.AlignTop
                    wrapMode: Text.Wrap
                    text: "<h1>Robz Play</h1> version %1
                        <p>PS5 Remote Play with PC frame generation.</p>
                        <h2>Based on chiaki-ng</h2> by Street Pea, a fork of Chiaki by Florian Markl

                        <p>This program is free software: you can redistribute it and/or modify
                        it under the terms of the GNU Affero General Public License version 3
                        as published by the Free Software Foundation.</p>

                        <p>This program is distributed in the hope that it will be useful,
                        but WITHOUT ANY WARRANTY; without even the implied warranty of
                        MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
                        GNU General Public License for more details.</p>".arg(Qt.application.version)
                }
            }
        }

        Dialog {
            id: keyDialog
            focus: false
            property int buttonValue
            property var buttonCallback
            property var keysIndex
            parent: Overlay.overlay
            x: Math.round((root.width - width) / 2)
            y: Math.round((root.height - height) / 2)
            title: qsTr("Key Capture")
            modal: true
            standardButtons: Dialog.Close
            closePolicy: Popup.CloseOnPressOutside
            onOpened: keyLabel.forceActiveFocus(Qt.TabFocusReason)
            onClosed: {
                let item = chiakiKeys.itemAt(keysIndex)
                if(item)
                {
                    let item2 = item.children[1];
                    if(item2)
                        item2.forceActiveFocus(Qt.TabFocusReason);
                }
                keyLabel.focus = false;
                focus = false;
            }
            Material.roundedScale: Material.MediumScale

            function show(opts) {
                buttonValue = opts.value;
                buttonCallback = opts.callback;
                keysIndex = opts.mappingIndex;
                open();
            }

            Label {
                id: keyLabel
                focus: true
                text: qsTr("Press any key to configure button or click close")
                Keys.onReleased: (event) => {
                    var name = Chiaki.settings.changeControllerKey(keyDialog.buttonValue, event.key);
                    keyDialog.buttonCallback(name);
                    keyDialog.close();
                }
            }
        }

        Dialog {
            id: controllerMappingDialog
            property bool resetFocus: true
            property bool resetMapping: false
            parent: Overlay.overlay
            x: Math.round((root.width - width) / 2)
            y: Math.round((root.height - height) / 2)
            title: qsTr("Controller Capture")
            modal: true
            standardButtons: Dialog.Close
            closePolicy: Popup.CloseOnPressOutside
            onOpened: {
                controllerLabel.forceActiveFocus(Qt.TabFocusReason);
                Chiaki.beginControllerMapping(resetMapping);
            }
            onClosed: {
                if(resetFocus)
                {
                    if(resetMapping)
                        controllerMappingReset.forceActiveFocus(Qt.TabFocusReason);
                    else
                        controllerMappingChange.forceActiveFocus(Qt.TabFocusReason);
                    focus = false;
                }
                else
                {
                    resetFocus = true;
                    focus = false;
                }
                if(quitControllerMapping)
                    Chiaki.controllerMappingQuit();
                else
                    quitControllerMapping = true;
            }
            Material.roundedScale: Material.MediumScale

            function show(opts) {
                resetMapping = opts.reset;
                open();
            }
            Label {
                id: controllerLabel
                text: qsTr("Choose the controller by pressing any button on the controller")
            }
        }

        Dialog {
            id: steamControllerMappingDialog
            property bool resetMapping: false
            parent: Overlay.overlay
            x: Math.round((root.width - width) / 2)
            y: Math.round((root.height - height) / 2)
            title: qsTr("Controller Managed by Steam")
            modal: true
            standardButtons: Dialog.Close
            closePolicy: Popup.NoAutoClose
            onOpened: {
                steamLabel.forceActiveFocus(Qt.TabFocusReason);
            }
            onClosed: {
                if(resetMapping)
                    controllerMappingReset.forceActiveFocus(Qt.TabFocusReason);
                else
                    controllerMappingChange.forceActiveFocus(Qt.TabFocusReason);
                focus = false;
            }
            Material.roundedScale: Material.MediumScale

            Label {
                id: steamLabel
                wrapMode: TextEdit.Wrap
                text: qsTr("This controller is managed by Steam.\nPlease use Steam to map controller or disable Steam Input for the controller before mapping here.")
                Keys.onReturnPressed: steamControllerMappingDialog.close();
                Keys.onEscapePressed: steamControllerMappingDialog.close();
            }
        }

        Connections {
            target: Chiaki

            function onControllerMappingInProgressChanged()
            {
                if(Chiaki.controllerMappingInProgress)
                    openTimer.start();
            }

            function onControllerMappingSteamControllerSelected()
            {
                controllerMappingDialog.resetFocus = false;
                quitControllerMapping = false;
                steamControllerMappingDialog.resetMapping = controllerMappingDialog.resetMapping;
                controllerMappingDialog.close();
                steamControllerMappingDialog.open();
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Window

import org.streetpea.chiaking

import "controls" as C

Item {
    id: view

    readonly property var hostWindow: view.Window.window
    property bool sessionError: false
    property bool sessionLoading: true
    property list<Item> restoreFocusItems
    readonly property bool useSeparateMenuWindow: Chiaki.window.runtimeRendererBackend === 1
    readonly property int streamMenuHeight: 200
    readonly property bool fpsCounterVisible: Chiaki.settings.showFpsCounter && Chiaki.session && !(menuController.open || menuController.closing) && !sessionLoading && !sessionError && !(Chiaki.settings.audioVideoDisabled & 0x02)
    readonly property bool streamStatsVisible: Chiaki.settings.showStreamStats && Chiaki.session && !(menuController.open || menuController.closing) && !sessionLoading && !sessionError && !(Chiaki.settings.audioVideoDisabled & 0x02)
    property int separateMenuX: 0
    property int separateMenuY: 0
    property int separateMenuWidth: 0
    property int separateStatsX: 0
    property int separateStatsY: 0
    property int separateStatsWidth: 0
    property int separateStatsHeight: 0
    property int separateDialogX: 0
    property int separateDialogY: 0
    property bool sessionStopDialogActive: false
    property bool sessionPinDialogActive: false
    readonly property bool hasVisibleStreamOverlay:
        loadingView.visible ||
        cantDisplayMessage.visible ||
        networkIndicatorButton.visible ||
        fpsCounter.visible ||
        menuView.visible ||
        sessionStopDialog.visible ||
        sessionPinDialog.visible

    function grabInput(item) {
        Chiaki.window.grabInput();
        restoreFocusItems.push(hostWindow ? hostWindow.activeFocusItem : null);
        if (item)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function releaseInput() {
        Chiaki.window.releaseInput();
        let item = restoreFocusItems.pop();
        if (item && item.visible)
            item.forceActiveFocus(Qt.TabFocusReason);
    }

    function updateSeparateMenuGeometry() {
        if (!hostWindow)
            return;
        const topLeft = view.mapToGlobal(0, 0);
        if (useSeparateMenuWindow) {
            separateMenuX = Math.round(topLeft.x);
            separateMenuY = Math.round(topLeft.y + view.height - streamMenuHeight);
            separateMenuWidth = Math.round(view.width);
            separateStatsX = Math.round(topLeft.x);
            separateStatsY = Math.round(topLeft.y);
            separateStatsWidth = Math.round(view.width);
            separateStatsHeight = Math.round(view.height);
        }
    }

    function updateSeparateDialogGeometry(width, height) {
        if (!useSeparateMenuWindow || !hostWindow)
            return;
        separateDialogX = Math.round(hostWindow.x + (hostWindow.width - width) / 2);
        separateDialogY = Math.round(hostWindow.y + (hostWindow.height - height) / 2);
    }

    function updateOverlayInteractionActive() {
        Chiaki.window.setOverlayInteractionActive(
            menuController.open ||
            menuController.closing ||
            sessionStopDialogActive ||
            separateSessionStopWindow.visible ||
            sessionPinDialogActive ||
            separateSessionPinWindow.visible
        );
    }

    StackView.onActivating: {
        Chiaki.window.keepVideo = true;
        sessionError = false;
        errorTitleLabel.text = "";
        errorTextLabel.text = "";
        sessionLoading = !(Chiaki.window.loadingTransitionComplete || (Chiaki.settings.audioVideoDisabled & 0x02));
    }
    StackView.onDeactivated: Chiaki.window.keepVideo = false

    Component.onCompleted: {
        updateSeparateMenuGeometry();
        updateOverlayInteractionActive();
        Chiaki.window.setStatsOverlayActive(streamStatsVisible);
    }
    onStreamStatsVisibleChanged: {
        if (Chiaki.window)
            Chiaki.window.setStatsOverlayActive(streamStatsVisible);
    }
    onWidthChanged: updateSeparateMenuGeometry()
    onHeightChanged: updateSeparateMenuGeometry()
    onUseSeparateMenuWindowChanged: updateSeparateMenuGeometry()

    Connections {
        target: view.hostWindow
        function onXChanged() { view.updateSeparateMenuGeometry() }
        function onYChanged() { view.updateSeparateMenuGeometry() }
        function onWidthChanged() { view.updateSeparateMenuGeometry() }
        function onHeightChanged() { view.updateSeparateMenuGeometry() }
        function onVisibilityChanged() { view.updateSeparateMenuGeometry() }
    }

    // One button of the stream menu: a filled tile that turns accent when it is switched on
    // and gets a light ring while the keyboard or a controller is on it.
    component MenuButton: ToolButton {
        id: menuButton
        implicitHeight: 44
        implicitWidth: Math.max(54, menuButtonLabel.implicitWidth + 30)
        padding: 0
        font.pixelSize: 15
        background: Rectangle {
            radius: 10
            color: menuButton.checked ? "#E4845E" : (menuButton.hovered ? "#4A3C36" : "#271F1C")
            border.width: menuButton.activeFocus ? 2 : 0
            border.color: "#FBF4EC"
            opacity: menuButton.enabled ? 1.0 : 0.5
        }
        contentItem: Label {
            id: menuButtonLabel
            text: menuButton.text
            font: menuButton.font
            color: menuButton.checked ? "#141110" : "#FBF4EC"
            opacity: menuButton.enabled ? 1.0 : 0.55
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
    }

    // Development aid (see QmlBackend::uiPreview): shows the menu without a console.
    Timer {
        interval: 700
        running: Chiaki.uiPreview === "stream-menu"
        onTriggered: {
            if (!menuController.open)
                menuController.toggle();
            Chiaki.window.requestOverlayUpdate();
        }
    }

    QtObject {
        id: menuController
        property bool closing: false
        property bool open: false

        property real lastToggleTime: 0
        function toggle() {
            var now = Date.now();
            if (now - lastToggleTime < 200)
                return;
            lastToggleTime = now;
            if (open)
                close();
            else {
                if (useSeparateMenuWindow) {
                    view.updateSeparateMenuGeometry();
                    view.grabInput(null);
                }
                open = true;
            }
            view.updateOverlayInteractionActive();
        }

        function close() {
            if (!open || closing)
                return;
            closing = true;
            open = false;
            view.releaseInput();
            view.updateOverlayInteractionActive();
        }
    }

    Rectangle {
        id: loadingView
        anchors.fill: parent
        color: "black"
        opacity: sessionError || sessionLoading || (Chiaki.settings.audioVideoDisabled & 0x02) ? 1.0 : 0.0
        visible: opacity

        Behavior on opacity { NumberAnimation { duration: 250 } }

        RobzBackdrop {
            anchors.fill: parent
        }

        Image {
            id: loadingLogo
            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.verticalCenter
                bottomMargin: 44
            }
            source: "qrc:/icons/robzplay.png"
            sourceSize: Qt.size(132, 132)
            visible: sessionLoading || sessionError
        }

        Label {
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: loadingLogo.bottom
                topMargin: 26
            }
            id: connectingLabel
            text: qsTr("Connecting to your PlayStation...")
            font.pixelSize: 24
            visible: sessionLoading
        }

        // Robz Play: this is when the PS5 asks which profile plays
        Label {
            anchors {
                horizontalCenter: parent.horizontalCenter
                top: connectingLabel.bottom
                topMargin: 14
            }
            width: Math.min(parent.width - 80, 760)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: qsTr("If the PS5 asks who plays, choose the <b>second profile</b>, not your main one. With a controller connected to this PC, the main profile works too.")
            textFormat: Text.StyledText
            color: "#CDBFB4"
            font.pixelSize: 16
            visible: sessionLoading
        }

        Item {
            anchors {
                top: parent.verticalCenter
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }

            BusyIndicator {
                id: spinner
                anchors.centerIn: parent
                width: 70
                height: width
                visible: sessionLoading
                running: sessionLoading
            }

            Label {
                anchors {
                    top: spinner.bottom
                    horizontalCenter: spinner.horizontalCenter
                    topMargin: 30
                }
                text: {
                    if(Chiaki.settings.dpadTouchEnabled)
                    {
                        if(Chiaki.settings.audioVideoDisabled == 0x01)
                            qsTr("Audio Disabled in settings\n") + qsTr("Press %1 to open stream menu").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : "Ctrl+O") + "\n" + qsTr("Press %1 to toggle between regular dpad and dpad touch").arg(Chiaki.settings.stringForDpadShortcut())
                        else
                            qsTr("Press %1 to open stream menu").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : "Ctrl+O") + "\n" + qsTr("Press %1 to toggle between regular dpad and dpad touch").arg(Chiaki.settings.stringForDpadShortcut())
                    }
                    else
                    {
                        if(Chiaki.settings.audioVideoDisabled == 0x01)
                            qsTr("Audio Disabled in settings\n") + qsTr("Press %1 to open stream menu").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : "Ctrl+O")
                        else
                            qsTr("Press %1 to open stream menu").arg(Chiaki.controllers.length ? Chiaki.settings.stringForStreamMenuShortcut() : "Ctrl+O")
                    }
                }
                visible: sessionLoading
            }

            Label {
                id: audioVideoDisabledTitleLabel
                anchors {
                    bottom: spinner.top
                    horizontalCenter: spinner.horizontalCenter
                }
                text: (Chiaki.settings.audioVideoDisabled & 0x01) ? qsTr("Audio and Video Disabled") : qsTr("Video Disabled")
                font.pixelSize: 24
                visible: !sessionLoading && !sessionError && (Chiaki.settings.audioVideoDisabled & 0x02)
            }

            Label {
                id: audioVideoDisabledTextLabel
                anchors {
                    top: audioVideoDisabledTitleLabel.bottom
                    horizontalCenter: audioVideoDisabledTitleLabel.horizontalCenter
                    topMargin: 10
                }
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 20
                text: (Chiaki.settings.audioVideoDisabled & 0x01) ? qsTr("You have disabled audio and video in your settings.\nTo re-enable change Audio/Video to Audio and Video Enabled in the General tab of the settings.") : qsTr("You have disabled video in your settings.\nTo re-enable change Audio/Video to Audio and Video Enabled in the General tab of the settings.")
                visible: !sessionLoading && !sessionError && (Chiaki.settings.audioVideoDisabled & 0x02)
            }

            Label {
                id: errorTitleLabel
                anchors {
                    bottom: spinner.top
                    horizontalCenter: spinner.horizontalCenter
                }
                font.pixelSize: 24
                visible: text
                onVisibleChanged: if (visible) view.grabInput(errorTitleLabel)
                Keys.onReturnPressed: root.showMainView()
                Keys.onEscapePressed: root.showMainView()
            }

            Label {
                id: errorTextLabel
                anchors {
                    top: errorTitleLabel.bottom
                    horizontalCenter: errorTitleLabel.horizontalCenter
                    topMargin: 10
                }
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 20
                visible: text
                width: Math.min(implicitWidth, view.width - 160)
                wrapMode: Text.Wrap
            }
        }
    }

    ColumnLayout {
        id: cantDisplayMessage
        anchors.centerIn: parent
        opacity: Chiaki.window.hasVideo && Chiaki.session && Chiaki.session.cantDisplay ? 1.0 : 0.0
        visible: opacity
        spacing: 30

        Behavior on opacity { NumberAnimation { duration: 250 } }

        onVisibleChanged: {
            if (visible) {
                menuController.close();
                view.grabInput(goToHomeButton);
            } else {
                view.releaseInput();
            }
        }

        Label {
            Layout.alignment: Qt.AlignCenter
            text: qsTr("The screen contains content that can't be displayed using Remote Play.")
        }

        Button {
            id: goToHomeButton
            Layout.alignment: Qt.AlignCenter
            Layout.preferredHeight: 60
            text: qsTr("Go to Home Screen")
            Material.background: activeFocus ? parent.Material.accent : undefined
            Material.roundedScale: Material.SmallScale
            onClicked: Chiaki.sessionGoHome()
            Keys.onReturnPressed: clicked()
            Keys.onEscapePressed: clicked()
        }
    }

    RoundButton {
        id: networkIndicatorButton
        anchors {
            right: parent.right
            top: parent.top
            margins: 40
        }
        icon.source: "qrc:/icons/discover-off-24px.svg"
        icon.width: 50
        icon.height: 50
        padding: 20
        checked: true
        opacity: networkIndicatorTimer.running ? 0.7 : 0.0
        visible: opacity
        Material.background: Material.accent

        Behavior on opacity { NumberAnimation { duration: 400 } }

        Timer {
            id: networkIndicatorTimer
            running: Chiaki.session?.averagePacketLoss > (Chiaki.settings.wifiDroppedNotif * 0.01)
            interval: 400
        }
    }

    Rectangle {
        id: fpsCounter
        readonly property bool generating: Chiaki.frameGen.enabled && Chiaki.frameGen.sourceFps > 1.0
            && Chiaki.frameGen.outputFps > Chiaki.frameGen.sourceFps * 1.3
        visible: view.fpsCounterVisible
        anchors {
            left: parent.left
            top: parent.top
            margins: 18
        }
        width: fpsCounterColumn.implicitWidth + 28
        height: fpsCounterColumn.implicitHeight + 17
        radius: 10
        color: Qt.rgba(0.078, 0.078, 0.075, 0.67)

        Column {
            id: fpsCounterColumn
            anchors.centerIn: parent
            spacing: 0

            Label {
                text: qsTr("%1 FPS").arg(Math.round(Chiaki.window.displayFps))
                color: "#E4845E"
                font.bold: true
                font.pixelSize: 26
            }

            Label {
                visible: fpsCounter.generating
                text: qsTr("source %1").arg(Math.round(Chiaki.frameGen.sourceFps))
                color: "#FBF4EC"
                font.pixelSize: 13
            }
        }
    }

    Component {
        id: streamStatsContent
        Item {
            id: streamStatsContentRoot
            anchors.fill: parent
            ColumnLayout {
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    rightMargin: 5
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: "Mbps"
                    font.pixelSize: 18
                    visible: Chiaki.session ? true : false

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.session.measuredBitrate.toFixed(1) : ""
                        color: Material.accent
                        font.bold: true
                        font.pixelSize: 28
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("queue depth avg")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.window.queueDepthAverage.toFixed(1) : ""
                        font.bold: true
                        color: "#90caf9"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("pending frame age")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? qsTr("%1 ms").arg((Chiaki.window.pendingFrameAge * 1000.0).toFixed(0)) : ""
                        font.bold: true
                        color: "#90caf9"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    id: statsPacketLossLabel
                    text: qsTr("packet loss")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? "%1<font size=\"1\">%</font>".arg((((Chiaki.session && isFinite(Chiaki.session.averagePacketLoss)) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1)) : ""
                        font.bold: true
                        color: "#ef9a9a"
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("dropped frames")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        id: statsDroppedFramesLabel
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? Chiaki.window.droppedFrames : ""
                        color: "#ef9a9a"
                        font.bold: true
                        font.pixelSize: 18
                    }
                }

                Label {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("lost frames")
                    font.pixelSize: 15
                    opacity: Chiaki.session ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 250 } }

                    Label {
                        anchors {
                            right: parent.left
                            baseline: parent.baseline
                            rightMargin: 5
                        }
                        text: parent.visible ? ((Chiaki.session && isFinite(Chiaki.session.framesLost)) ? Chiaki.session.framesLost : 0) : ""
                        color: "#ef9a9a"
                        font.bold: true
                        font.pixelSize: 18
                    }
                }
            }
        }
    }

    // The stream menu: a dock along the bottom of the picture. Everything that applies while
    // playing is one row of buttons away; the connection figures sit on the right.
    Component {
        id: menuContentComponent

        Item {
            property Item initialFocusItem: closeButton
            anchors.fill: parent

            // a soft shade, so the dock reads on any picture
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: "#00000000" }
                    GradientStop { position: 1.0; color: "#B8000000" }
                }
            }

            Rectangle {
                id: dock
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: 20
                    rightMargin: 20
                    bottomMargin: 18
                }
                height: 142
                radius: 18
                color: "#F2171312"
                border.color: "#3B302B"

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 18
                        rightMargin: 24
                        topMargin: 14
                        bottomMargin: 14
                    }
                    spacing: 16

                    MenuButton {
                        id: closeButton
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 58
                        implicitHeight: 58
                        text: "×"
                        font.pixelSize: 32
                        down: activeFocus
                        onClicked: {
                            if (Chiaki.session)
                                Chiaki.window.close();
                            else
                                root.showMainView();
                        }
                        KeyNavigation.right: volumeSlider
                        Keys.onReturnPressed: clicked()
                        Keys.onEscapePressed: menuController.close()
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 1
                        implicitHeight: 84
                        color: "#3B302B"
                    }

                    ColumnLayout {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 10

                        // sound and picture
                        RowLayout {
                            spacing: 8

                            Label {
                                text: qsTr("Volume")
                                color: "#CDBFB4"
                                font.pixelSize: 14
                            }

                            Slider {
                                id: volumeSlider
                                Layout.preferredWidth: 130
                                from: 0
                                to: 128
                                stepSize: 1
                                value: Chiaki.settings.audioVolume
                                onMoved: Chiaki.settings.audioVolume = value
                                // Left and right change the volume, down goes to the row below. Down
                                // used to lower the volume, so moving through the menu with a
                                // controller could turn the sound all the way off.
                                KeyNavigation.down: defaultButton
                                Keys.onEscapePressed: menuController.close()
                            }

                            Label {
                                Layout.preferredWidth: 46
                                Layout.rightMargin: 6
                                text: ((volumeSlider.value / 128.0) * 100).toFixed(0) + "%"
                                color: "#FBF4EC"
                                font.pixelSize: 14
                            }

                            MenuButton {
                                id: muteButton
                                text: qsTr("Mic")
                                checkable: true
                                enabled: Chiaki.session && Chiaki.session.connected
                                checked: Chiaki.session && !Chiaki.session.muted
                                onToggled: Chiaki.session.muted = !Chiaki.session.muted
                                KeyNavigation.left: volumeSlider
                                KeyNavigation.right: zoomButton
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: zoomButton
                                text: qsTr("Zoom")
                                checkable: true
                                checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                                onToggled: Chiaki.window.videoMode = Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom ? ChiakiWindow.VideoMode.Normal : ChiakiWindow.VideoMode.Zoom
                                KeyNavigation.left: muteButton
                                KeyNavigation.right: {
                                    if(Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom)
                                        zoomFactor
                                    else
                                        stretchButton
                                }
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            Slider {
                                id: zoomFactor
                                Layout.preferredWidth: 120
                                from: -1
                                to: 4
                                stepSize: 0.01
                                visible: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom
                                value: Chiaki.window.ZoomFactor
                                onMoved: {
                                    Chiaki.window.ZoomFactor = value
                                    Chiaki.settings.sZoomFactor = value
                                }
                                // left and right change the zoom, down goes to the row below
                                KeyNavigation.down: defaultButton
                                Keys.onEscapePressed: menuController.close()
                            }

                            Label {
                                Layout.rightMargin: 6
                                visible: zoomFactor.visible
                                color: "#FBF4EC"
                                font.pixelSize: 14
                                text: {
                                    if(zoomFactor.value === -1)
                                        qsTr("No Black Bars")
                                    else if(zoomFactor.value >= 0)
                                        qsTr((zoomFactor.value + 1).toFixed(2)) + qsTr(" x")
                                    else
                                        qsTr(zoomFactor.value.toFixed(2)) + qsTr(" x")
                                }
                            }

                            MenuButton {
                                id: stretchButton
                                text: qsTr("Stretch")
                                checkable: true
                                checked: Chiaki.window.videoMode == ChiakiWindow.VideoMode.Stretch
                                onToggled: Chiaki.window.videoMode = Chiaki.window.videoMode == ChiakiWindow.VideoMode.Stretch ? ChiakiWindow.VideoMode.Normal : ChiakiWindow.VideoMode.Stretch
                                KeyNavigation.left: {
                                    if(Chiaki.window.videoMode == ChiakiWindow.VideoMode.Zoom)
                                        zoomFactor
                                    else
                                        zoomButton
                                }
                                KeyNavigation.right: fpsCounterButton
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: fpsCounterButton
                                text: qsTr("FPS counter")
                                checkable: true
                                checked: Chiaki.settings.showFpsCounter
                                onToggled: Chiaki.settings.showFpsCounter = !Chiaki.settings.showFpsCounter
                                KeyNavigation.left: stretchButton
                                KeyNavigation.right: compareButton
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: compareButton
                                text: qsTr("30 / 60 comparison")
                                checkable: true
                                checked: Chiaki.settings.frameGenCompare
                                onToggled: Chiaki.settings.frameGenCompare = !Chiaki.settings.frameGenCompare
                                KeyNavigation.left: fpsCounterButton
                                KeyNavigation.right: sharpenButton
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: sharpenButton
                                readonly property int level: Math.max(0, Math.min(3, Chiaki.settings.sharpening))
                                text: qsTr("Sharpening: %1").arg([qsTr("Off"), qsTr("Low"), qsTr("Medium"), qsTr("High")][level])
                                onClicked: Chiaki.settings.sharpening = (level + 1) % 4
                                KeyNavigation.left: compareButton
                                KeyNavigation.right: enhanceButton
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: clicked()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: enhanceButton
                                readonly property int mode: Math.max(0, Math.min(4, Chiaki.settings.pictureEnhanceMode))
                                text: qsTr("Enhance: %1").arg([qsTr("Off"), qsTr("Adaptive"), qsTr("AMD CAS"), qsTr("Cinema"), qsTr("Ultra Crisp")][mode])
                                onClicked: Chiaki.settings.pictureEnhanceMode = (mode + 1) % 5
                                KeyNavigation.left: sharpenButton
                                KeyNavigation.right: defaultButton
                                KeyNavigation.down: defaultButton
                                Keys.onReturnPressed: clicked()
                                Keys.onEscapePressed: menuController.close()
                            }
                        }

                        // how the picture is drawn
                        RowLayout {
                            spacing: 8

                            Label {
                                Layout.rightMargin: 4
                                text: qsTr("Renderer")
                                color: "#CDBFB4"
                                font.pixelSize: 14
                            }

                            MenuButton {
                                id: defaultButton
                                text: qsTr("Default")
                                checkable: true
                                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Default
                                onToggled: {
                                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Default
                                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.Default
                                }
                                KeyNavigation.left: sharpenButton
                                KeyNavigation.right: highQualityButton
                                KeyNavigation.up: muteButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: highQualityButton
                                text: qsTr("High Quality")
                                checkable: true
                                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.HighQuality
                                onToggled: {
                                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQuality
                                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.HighQuality
                                }
                                KeyNavigation.left: defaultButton
                                KeyNavigation.right: highQualitySpatialButton
                                KeyNavigation.up: muteButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: highQualitySpatialButton
                                text: qsTr("HQ + Spatial")
                                checkable: true
                                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.HighQualitySpatial
                                onToggled: {
                                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQualitySpatial
                                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.HighQualitySpatial
                                }
                                KeyNavigation.left: highQualityButton
                                KeyNavigation.right: highQualityAdvancedSpatialButton
                                KeyNavigation.up: muteButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: highQualityAdvancedSpatialButton
                                text: qsTr("HQ + Adv Spatial")
                                checkable: true
                                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial
                                onToggled: {
                                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial
                                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.HighQualityAdvancedSpatial
                                }
                                KeyNavigation.left: highQualitySpatialButton
                                KeyNavigation.right: customButton
                                KeyNavigation.up: muteButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: customButton
                                Layout.rightMargin: 14
                                text: qsTr("Custom")
                                checkable: true
                                checked: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom
                                onToggled: {
                                    Chiaki.window.videoPreset = ChiakiWindow.VideoPreset.Custom
                                    Chiaki.settings.videoPreset = ChiakiWindow.VideoPreset.Custom
                                }
                                KeyNavigation.left: highQualityAdvancedSpatialButton
                                KeyNavigation.right: displaySettingsButton
                                KeyNavigation.up: muteButton
                                Keys.onReturnPressed: toggled()
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: displaySettingsButton
                                text: qsTr("Display settings")
                                checkable: false
                                onClicked: root.openDisplaySettings()
                                KeyNavigation.left: customButton
                                KeyNavigation.right: {
                                    if(Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom)
                                        placeboSettingsButton;
                                    else
                                        displaySettingsButton;
                                }
                                KeyNavigation.up: muteButton
                                Keys.onReturnPressed: {
                                    menuController.close();
                                    clicked();
                                }
                                Keys.onEscapePressed: menuController.close()
                            }

                            MenuButton {
                                id: placeboSettingsButton
                                text: qsTr("Renderer settings")
                                checkable: false
                                onClicked: root.openPlaceboSettings()
                                KeyNavigation.left: displaySettingsButton
                                KeyNavigation.up: muteButton
                                visible: Chiaki.window.videoPreset == ChiakiWindow.VideoPreset.Custom
                                Keys.onReturnPressed: {
                                    menuController.close();
                                    clicked();
                                }
                                Keys.onEscapePressed: menuController.close()
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    // the connection, in figures
                    ColumnLayout {
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        spacing: 2

                        Label {
                            id: consoleNameLabel
                            Layout.alignment: Qt.AlignRight
                            color: "#CDBFB4"
                            font.pixelSize: 14
                            text: {
                                if (!Chiaki.session)
                                    return "";
                                if (Chiaki.session.connected)
                                    return qsTr("Connected to <b>%1</b>").arg(Chiaki.settings.streamerMode ? qsTr("hidden") : Chiaki.session.host);
                                return qsTr("Connecting to <b>%1</b>").arg(Chiaki.settings.streamerMode ? qsTr("hidden") : Chiaki.session.host);
                            }
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            visible: Chiaki.session ? true : false
                            spacing: 6

                            Label {
                                text: visible && Chiaki.session ? Chiaki.session.measuredBitrate.toFixed(1) : ""
                                color: Material.accent
                                font.bold: true
                                font.pixelSize: 28
                            }

                            Label {
                                Layout.alignment: Qt.AlignBaseline
                                text: "Mbps"
                                color: "#CDBFB4"
                                font.pixelSize: 16
                            }
                        }

                        Label {
                            Layout.alignment: Qt.AlignRight
                            visible: Chiaki.session && Chiaki.frameGen.enabled && Chiaki.frameGen.sourceFps > 1.0 ? true : false
                            text: visible ? qsTr("Frame generation %1 → %2 FPS").arg(Math.round(Chiaki.frameGen.sourceFps)).arg(Math.round(Chiaki.frameGen.outputFps)) : ""
                            color: "#FBF4EC"
                            font.pixelSize: 14
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            visible: Chiaki.session ? true : false
                            spacing: 6

                            Label {
                                text: visible ? "%1%".arg((((Chiaki.session && isFinite(Chiaki.session.averagePacketLoss)) ? Chiaki.session.averagePacketLoss : 0) * 100).toFixed(1)) : ""
                                color: "#ef9a9a" // Material.Red
                                font.bold: true
                                font.pixelSize: 14
                            }

                            Label {
                                text: qsTr("packet loss")
                                color: "#CDBFB4"
                                font.pixelSize: 13
                            }

                            Label {
                                id: droppedFramesLabel
                                Layout.leftMargin: 8
                                visible: Chiaki.window.droppedFrames ? true : false
                                text: visible ? Chiaki.window.droppedFrames : ""
                                color: "#ef9a9a" // Material.Red
                                font.bold: true
                                font.pixelSize: 14
                            }

                            Label {
                                visible: droppedFramesLabel.visible
                                text: qsTr("dropped frames")
                                color: "#CDBFB4"
                                font.pixelSize: 13
                            }
                        }
                    }
                }
            }
        }
    }

    Item {
        id: menuView
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
        }
        height: streamMenuHeight
        y: menuController.open ? parent.height - height : parent.height
        visible: !useSeparateMenuWindow && (menuController.open || menuController.closing)
        enabled: !useSeparateMenuWindow && menuController.open
        onVisibleChanged: {
            if (visible)
                view.grabInput(inlineMenuContent.item ? inlineMenuContent.item.initialFocusItem : null);
        }

        Behavior on y {
            NumberAnimation {
                id: inlineMenuAnimation
                duration: 250
                onRunningChanged: {
                    if (!running && !menuController.open) {
                        menuController.closing = false;
                        view.updateOverlayInteractionActive();
                    }
                }
            }
        }

        Loader {
            id: inlineMenuContent
            anchors.fill: parent
            active: !useSeparateMenuWindow
            sourceComponent: menuContentComponent
        }
    }

    StreamMenuWindow {
        id: separateMenuWindow
        transientParent: view.hostWindow
        x: separateMenuX
        y: menuController.open ? separateMenuY : separateMenuY + streamMenuHeight
        width: separateMenuWidth > 0 ? separateMenuWidth : view.width
        height: streamMenuHeight
        open: useSeparateMenuWindow && menuController.open
        closing: useSeparateMenuWindow && menuController.closing
        onCloseRequested: menuController.close()
        onDisplaySettingsRequested: {
            menuController.close();
            root.openDisplaySettings();
        }
        onPlaceboSettingsRequested: {
            menuController.close();
            root.openPlaceboSettings();
        }
        onMainViewRequested: root.showMainView()
        onCloseAnimationFinished: {
            if (view.hostWindow)
                view.hostWindow.requestActivate();
            menuController.closing = false;
            view.updateOverlayInteractionActive();
        }
    }

    Popup {
        id: sessionStopDialog
        property int closeAction: 0
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        modal: true
        padding: 30
        onAboutToShow: {
            closeAction = 0;
            sessionStopDialogActive = true;
            view.updateOverlayInteractionActive();
        }
        onClosed: {
            view.releaseInput();
            sessionStopDialogActive = false;
            view.updateOverlayInteractionActive();
            if (closeAction)
                Chiaki.stopSession(closeAction == 1);
        }

        ColumnLayout {
            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Disconnect Session")
                font.bold: true
                font.pixelSize: 24
            }

            Label {
                Layout.topMargin: 10
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Do you want the Console to go into sleep mode?")
                font.pixelSize: 20
            }

            RowLayout {
                Layout.topMargin: 30
                Layout.alignment: Qt.AlignCenter
                spacing: 30

                Button {
                    id: sleepButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Sleep")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.right: noButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: sessionStopDialog.close()
                    onVisibleChanged: if (visible) view.grabInput(sleepButton)
                    onClicked: {
                        sessionStopDialog.closeAction = 1;
                        sessionStopDialog.close();
                    }
                }

                Button {
                    id: noButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("No")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.left: sleepButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: sessionStopDialog.close()
                    onClicked: {
                        sessionStopDialog.closeAction = 2;
                        sessionStopDialog.close();
                    }
                }
            }
        }
    }

    Window {
        id: separateSessionStopWindow
        property int closeAction: 0
        readonly property int dialogWidth: 700
        readonly property int dialogHeight: 260
        visible: false
        flags: Qt.Dialog | Qt.FramelessWindowHint
        color: "transparent"
        transientParent: view.hostWindow
        modality: Qt.ApplicationModal
        x: separateDialogX
        y: separateDialogY
        width: dialogWidth
        height: dialogHeight

        onVisibleChanged: {
            if (visible) {
                closeAction = 0;
                view.updateSeparateDialogGeometry(width, height);
                requestActivate();
                view.grabInput(separateSleepButton);
            } else {
                view.releaseInput();
                if (closeAction)
                    Chiaki.stopSession(closeAction === 1);
            }
            view.updateOverlayInteractionActive();
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Material.background
            border.color: "#666666"
            border.width: 1
        }

        ColumnLayout {
            anchors.centerIn: parent

            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Disconnect Session")
                font.bold: true
                font.pixelSize: 24
            }

            Label {
                Layout.topMargin: 10
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Do you want the Console to go into sleep mode?")
                font.pixelSize: 20
            }

            RowLayout {
                Layout.topMargin: 30
                Layout.alignment: Qt.AlignCenter
                spacing: 30

                Button {
                    id: separateSleepButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("Sleep")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.right: separateNoButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: separateSessionStopWindow.visible = false
                    onClicked: {
                        separateSessionStopWindow.closeAction = 1;
                        separateSessionStopWindow.visible = false;
                    }
                }

                Button {
                    id: separateNoButton
                    Layout.preferredWidth: 200
                    Layout.minimumHeight: 80
                    Layout.maximumHeight: 80
                    text: qsTr("No")
                    font.pixelSize: 24
                    Material.roundedScale: Material.SmallScale
                    Material.background: activeFocus ? parent.Material.accent : undefined
                    KeyNavigation.left: separateSleepButton
                    Keys.onReturnPressed: clicked()
                    Keys.onEscapePressed: separateSessionStopWindow.visible = false
                    onClicked: {
                        separateSessionStopWindow.closeAction = 2;
                        separateSessionStopWindow.visible = false;
                    }
                }
            }
        }
    }

    Dialog {
        id: sessionPinDialog
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        title: qsTr("Console Login PIN")
        modal: true
        closePolicy: Popup.NoAutoClose
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAboutToShow: {
            standardButton(Dialog.Ok).enabled = Qt.binding(function() {
                return pinField.acceptableInput;
            });
            view.grabInput(pinField);
            sessionPinDialogActive = true;
            view.updateOverlayInteractionActive();
        }
        onClosed: {
            view.releaseInput();
            sessionPinDialogActive = false;
            view.updateOverlayInteractionActive();
        }
        onAccepted: Chiaki.enterPin(pinField.text)
        onRejected: Chiaki.stopSession(false)
        Material.roundedScale: Material.MediumScale

        TextField {
            id: pinField
            echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
            implicitWidth: 200
            validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
            Keys.onReturnPressed: {
                if(sessionPinDialog.standardButton(Dialog.Ok).enabled)
                    sessionPinDialog.standardButton(Dialog.Ok).clicked()
            }
        }
    }

    Window {
        id: separateSessionPinWindow
        readonly property int dialogWidth: 360
        readonly property int dialogHeight: 220
        visible: false
        flags: Qt.Dialog | Qt.FramelessWindowHint
        color: "transparent"
        transientParent: view.hostWindow
        modality: Qt.ApplicationModal
        x: separateDialogX
        y: separateDialogY
        width: dialogWidth
        height: dialogHeight

        onVisibleChanged: {
            if (visible) {
                separatePinField.text = "";
                view.updateSeparateDialogGeometry(width, height);
                requestActivate();
                view.grabInput(separatePinField);
            } else {
                view.releaseInput();
            }
            view.updateOverlayInteractionActive();
        }

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: Material.background
            border.color: "#666666"
            border.width: 1
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 24
            }

            Label {
                Layout.alignment: Qt.AlignCenter
                text: qsTr("Console Login PIN")
                font.bold: true
                font.pixelSize: 24
            }

            TextField {
                id: separatePinField
                Layout.topMargin: 20
                Layout.fillWidth: true
                echoMode: Chiaki.settings.streamerMode ? TextInput.Password : TextInput.Normal
                validator: RegularExpressionValidator { regularExpression: /[0-9]{4}/ }
                Keys.onReturnPressed: if (acceptableInput) separatePinOkButton.clicked()
                Keys.onEscapePressed: separateSessionPinWindow.visible = false
            }

            RowLayout {
                Layout.topMargin: 20
                Layout.alignment: Qt.AlignRight
                spacing: 16

                Button {
                    text: qsTr("Cancel")
                    Keys.onReturnPressed: clicked()
                    onClicked: {
                        separateSessionPinWindow.visible = false;
                        Chiaki.stopSession(false);
                    }
                }

                Button {
                    id: separatePinOkButton
                    text: qsTr("OK")
                    enabled: separatePinField.acceptableInput
                    Keys.onReturnPressed: clicked()
                    onClicked: {
                        const pin = separatePinField.text;
                        separateSessionPinWindow.visible = false;
                        Chiaki.enterPin(pin);
                    }
                }
            }
        }
    }

    Timer {
        id: closeTimer
        // an error that says what to do stays long enough to be read
        interval: errorTextLabel.text.length > 90 ? 9000 : 2000
        onTriggered: root.showMainView()
    }

    Connections {
        target: Chiaki

        function onSessionChanged() {
            if (!Chiaki.session) {
                if (errorTitleLabel.text)
                    closeTimer.start();
                else
                    root.showMainView();
            } else {
                sessionError = false;
                errorTitleLabel.text = "";
                errorTextLabel.text = "";
                sessionLoading = !(Chiaki.window.loadingTransitionComplete || (Chiaki.settings.audioVideoDisabled & 0x02));
            }
        }

        function onSessionError(title, text) {
            sessionError = true;
            sessionLoading = false;
            errorTitleLabel.text = title;
            errorTextLabel.text = text;
            closeTimer.start();
        }

        function onSessionPinDialogRequested() {
            if (sessionPinDialog.opened || separateSessionPinWindow.visible)
                return;
            menuController.close();
            if (useSeparateMenuWindow)
                separateSessionPinWindow.visible = true;
            else
                sessionPinDialog.open();
            Chiaki.window.requestOverlayUpdate();
        }

        function onSessionStopDialogRequested() {
            if (sessionStopDialog.opened || separateSessionStopWindow.visible)
                return;
            menuController.close();
            if (useSeparateMenuWindow)
                separateSessionStopWindow.visible = true;
            else
                sessionStopDialog.open();
            Chiaki.window.requestOverlayUpdate();
        }
    }

    Connections {
        target: Chiaki.window

        function onLoadingTransitionCompleteChanged() {
            if (Chiaki.window.loadingTransitionComplete) {
                sessionLoading = false;
                Chiaki.window.noteLoadingTransitionComplete();
                Chiaki.window.requestOverlayUpdate();
            } else if (Chiaki.session) {
                sessionLoading = !(Chiaki.settings.audioVideoDisabled & 0x02);
            }
        }

        function onMenuRequested() {
            if (sessionPinDialog.opened || sessionStopDialog.opened || separateSessionPinWindow.visible || separateSessionStopWindow.visible)
                return;
            menuController.toggle();
            Chiaki.window.requestOverlayUpdate();
        }
    }
    Connections {
        target: Chiaki

        function onSessionChanged() {
            if (!Chiaki.session)
                menuController.close();
        }
    }
    Connections {
        target: Chiaki.session

        function onConnectedChanged() {
            if (Chiaki.settings.audioVideoDisabled & 0x02)
                sessionLoading = false;
        }
    }
}

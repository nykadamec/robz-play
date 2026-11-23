import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

import org.streetpea.chiaking

Pane {
    padding: 0
    id: consolePane
    StackView.onActivated: {
        forceActiveFocus(Qt.TabFocusReason);
        updateOfferTimer.restart();
        if(!Chiaki.autoConnect && !root.initialAsk && !Chiaki.window.directStream)
        {
            root.initialAsk = true;
            // Robz Play: no start-up questions - neither about a Steam shortcut (it can still be
            // made from the main menu, button or R3) nor about Remote Play via PSN (signing in to
            // PSN is under Settings > Remote play, and setting up a console signs in anyway)
        }
    }
    Keys.onUpPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            hostsView.decrementCurrentIndex()
            while(!hostsView.currentItem.visible)
                hostsView.decrementCurrentIndex()
        }
    }
    Keys.onDownPressed: {
        if(hostsView.currentItem && hostsView.currentItem.visible)
        {
            hostsView.incrementCurrentIndex()
            while(!hostsView.currentItem.visible)
                 hostsView.incrementCurrentIndex()
        }
    }
    Keys.onMenuPressed: settingsButton.clicked()
    Keys.onReturnPressed: if (hostsView.currentItem) hostsView.currentItem.connectToHost()
    Keys.onYesPressed: if (hostsView.currentItem) hostsView.currentItem.wakeUpHost()
    Keys.onNoPressed: if (hostsView.currentItem) hostsView.currentItem.deleteHost()
    Keys.onEscapePressed: root.showConfirmDialog(qsTr("Quit"), qsTr("Are you sure you want to quit?"), () => Qt.quit())
    Keys.onPressed: (event) => {
        if (event.modifiers)
            return;
        switch (event.key) {
        case Qt.Key_PageUp:
            if (hostsView.currentItem) hostsView.currentItem.setConsolePin();
            event.accepted = true;
            break;
        case Qt.Key_PageDown:
            if (Chiaki.settings.psnAuthToken) Chiaki.refreshPsnToken();
            event.accepted = true;
            break;
        case Qt.Key_F1:
            if (typeof Chiaki.createSteamShortcut === "function") root.showSteamShortcutDialog(false);
            event.accepted = true;
            break;
        case Qt.Key_F2:
            root.showManualHostDialog();
            event.accepted = true;
            break;
        }
    }

    // ------------------------------------------------------------------ look
    // Robz Play home screen: brand and navigation on the left, consoles in the middle, and
    // the frame generation panel - with a live picture of what it does - on the right.
    // Warm dark palette.
    readonly property color cBg: "#141110"
    readonly property color cSidebar: "#100D0C"
    readonly property color cSurface: "#1D1816"
    readonly property color cSurfaceHover: "#271F1C"
    readonly property color cInset: "#171312"
    readonly property color cBorder: "#3B302B"
    readonly property color cText: "#FBF4EC"
    readonly property color cMuted: "#CDBFB4"
    readonly property color cFaint: "#A08F84"
    readonly property color cAccent: "#E4845E"
    readonly property color cAccentHover: "#F09A74"
    readonly property color cOnAccent: "#141110"
    readonly property color cGood: "#8DB580"
    readonly property color cWarn: "#D9A65A"
    // titles in the heavy italic of the icon's letters (Segoe UI Black)
    readonly property string display: "Segoe UI"

    // room for the wide layout; below it the sidebar and the panel slim down
    readonly property bool roomy: width >= 1320

    readonly property bool previewEmpty: Chiaki.uiPreview === "home-empty"

    readonly property int visibleHosts: {
        if (previewEmpty)
            return 0;
        let n = 0;
        const hosts = Chiaki.hosts;
        for (let i = 0; i < hosts.length; ++i) {
            if (hosts[i].display)
                n++;
        }
        return n;
    }

    // consoles that still have to be linked with the code from the console
    readonly property int hostsToSetUp: {
        let n = 0;
        const hosts = Chiaki.hosts;
        for (let i = 0; i < hosts.length; ++i) {
            if (hosts[i].display && !hosts[i].registered && !hosts[i].duid)
                n++;
        }
        return n;
    }

    // room for the explanations inside the picture mode tiles
    readonly property bool tall: height >= 840

    // the stream the console is asked for on the home network, as set under Settings > Stream
    readonly property string streamResolution: ["360p", "540p", "720p", "1080p"][Math.max(1, Math.min(4, Chiaki.settings.resolutionLocalPS5)) - 1]

    // Drives the moving markers of the picture mode tiles. It only runs while this
    // screen is the one on show and the app is in front.
    property real cadencePhase: 0
    NumberAnimation on cadencePhase {
        from: 0
        to: 1
        duration: 1800
        loops: Animation.Infinite
        running: consolePane.StackView.status === StackView.Active && Qt.application.state === Qt.ApplicationActive
    }

    background: Rectangle { color: consolePane.cBg }

    // A row in the sidebar.
    component NavButton: AbstractButton {
        id: nav
        property string hint: ""
        Layout.fillWidth: true
        implicitHeight: 46
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        background: Rectangle {
            radius: 10
            color: nav.down ? "#271F1C" : (nav.hovered ? "#1D1816" : "transparent")
        }
        contentItem: RowLayout {
            spacing: 10
            Label {
                Layout.fillWidth: true
                Layout.leftMargin: 14
                text: nav.text
                color: "#FBF4EC"
                font.pixelSize: 17
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
            Label {
                Layout.rightMargin: 14
                visible: nav.hint.length > 0
                text: nav.hint
                color: "#A08F84"
                font.pixelSize: 13
                verticalAlignment: Text.AlignVCenter
            }
        }
    }

    // An on/off switch. `on` is bound to a setting; clicking asks the owner to change it.
    component Toggle: AbstractButton {
        id: toggle
        property bool on: false
        implicitWidth: 46
        implicitHeight: 26
        focusPolicy: Qt.NoFocus
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        background: Rectangle {
            radius: height / 2
            color: toggle.on ? "#E4845E" : "#4E403A"
            Behavior on color { ColorAnimation { duration: 120 } }
            Rectangle {
                width: 20
                height: 20
                radius: 10
                y: 3
                x: toggle.on ? parent.width - width - 3 : 3
                color: "#FBF4EC"
                Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            }
        }
    }

    // One choice of a segmented control. `active` is bound to a setting. `badge` is a small
    // note next to the text, such as "Experimental".
    component Segment: AbstractButton {
        id: segment
        property bool active: false
        property string badge: ""
        Layout.fillWidth: true
        implicitHeight: 34
        implicitWidth: Math.max(64, segmentContent.implicitWidth + 22)
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        background: Rectangle {
            radius: 8
            color: segment.active ? "#E4845E" : (segment.hovered ? "#271F1C" : "transparent")
        }
        contentItem: Item {
            implicitWidth: segmentContent.implicitWidth
            implicitHeight: segmentContent.implicitHeight
            Row {
                id: segmentContent
                anchors.centerIn: parent
                spacing: 7
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: segment.text
                    color: segment.active ? "#141110" : "#CDBFB4"
                    font.pixelSize: 15
                    font.weight: segment.active ? Font.DemiBold : Font.Normal
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: segment.badge.length > 0
                    width: segmentBadge.implicitWidth + 12
                    height: 18
                    radius: 9
                    color: segment.active ? "#2E141110" : "transparent"
                    border.width: segment.active ? 0 : 1
                    border.color: "#D9A65A"
                    Label {
                        id: segmentBadge
                        anchors.centerIn: parent
                        text: segment.badge
                        color: segment.active ? "#141110" : "#D9A65A"
                        font.pixelSize: 11
                    }
                }
            }
        }
    }

    // The frame around a row of segments; the segments share its width evenly.
    component SegmentGroup: Rectangle {
        default property alias segments: segmentRow.data
        Layout.fillWidth: true
        implicitWidth: segmentRow.implicitWidth + 6
        implicitHeight: 40
        radius: 10
        color: "#171312"
        border.color: "#3B302B"
        RowLayout {
            id: segmentRow
            anchors {
                fill: parent
                margins: 3
            }
            spacing: 2
            uniformCellSizes: true
        }
    }

    // A language choice, shown as its flag.
    component FlagButton: AbstractButton {
        id: flag
        property string code: ""
        property bool active: false
        implicitWidth: 46
        implicitHeight: 32
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        background: Rectangle {
            radius: 8
            color: flag.active ? "#271F1C" : (flag.hovered ? "#1D1816" : "transparent")
            border.width: flag.active ? 2 : 1
            border.color: flag.active ? "#E4845E" : "#3B302B"
        }
        contentItem: Item {
            Image {
                anchors.centerIn: parent
                width: 27
                height: 18
                sourceSize: Qt.size(54, 36)
                source: "qrc:/icons/flag-" + flag.code + ".svg"
                opacity: flag.active ? 1.0 : 0.55
            }
        }
    }

    // A quiet text button used for the secondary actions on a console card.
    component CardAction: AbstractButton {
        id: cardAction
        property string glyph: ""
        property bool showGlyph: false
        implicitHeight: 34
        implicitWidth: cardActionRow.implicitWidth + 24
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        background: Rectangle {
            radius: 8
            color: cardAction.hovered ? "#171312" : "transparent"
            border.color: "#3B302B"
            border.width: 1
        }
        contentItem: Item {
            implicitWidth: cardActionRow.implicitWidth
            Row {
                id: cardActionRow
                anchors.centerIn: parent
                spacing: 8
                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: cardAction.showGlyph && cardAction.glyph.length > 0
                    width: 20
                    height: 20
                    sourceSize: Qt.size(width, height)
                    source: visible ? cardAction.glyph : ""
                }
                Label {
                    anchors.verticalCenter: parent.verticalCenter
                    text: cardAction.text
                    color: "#CDBFB4"
                    font.pixelSize: 14
                }
            }
        }
    }

    // One picture mode: what it is called, what it does, and - as a marker that moves at
    // that rate - what a 30 FPS game looks like in it.
    component ModeTile: AbstractButton {
        id: tile
        property bool active: false
        property string title: ""
        property string badge: ""
        property color badgeTint: "#D9A65A"
        property string summary: ""
        property bool showSummary: true
        property string result: ""
        property int laneFps: 30
        property real phase: 0
        Layout.fillWidth: true
        Layout.fillHeight: true
        implicitHeight: tileColumn.implicitHeight + 34
        focusPolicy: Qt.NoFocus
        hoverEnabled: true
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        background: Rectangle {
            radius: 14
            color: tile.active ? "#2C221E" : (tile.hovered ? "#1A1514" : "#171312")
            border.width: tile.active ? 2 : 1
            border.color: tile.active ? "#E4845E" : (tile.hovered ? "#5E4E46" : "#3B302B")
        }
        contentItem: Item {
            implicitHeight: tileColumn.implicitHeight
            ColumnLayout {
                id: tileColumn
                anchors {
                    fill: parent
                    margins: 17
                }
                spacing: 9

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 18
                        implicitHeight: 18
                        radius: 9
                        color: "transparent"
                        border.width: 2
                        border.color: tile.active ? "#E4845E" : "#75655B"
                        Rectangle {
                            anchors.centerIn: parent
                            width: 8
                            height: 8
                            radius: 4
                            color: "#E4845E"
                            visible: tile.active
                        }
                    }
                    Label {
                        text: tile.title
                        color: "#FBF4EC"
                        font.pixelSize: 20
                        font.weight: Font.DemiBold
                    }
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        visible: tile.badge.length > 0
                        implicitWidth: tileBadge.implicitWidth + 14
                        implicitHeight: 20
                        radius: 10
                        color: "transparent"
                        border.color: tile.badgeTint
                        Label {
                            id: tileBadge
                            anchors.centerIn: parent
                            text: tile.badge
                            color: tile.badgeTint
                            font.pixelSize: 12
                        }
                    }
                    Item { Layout.fillWidth: true }
                }

                Label {
                    Layout.fillWidth: true
                    visible: tile.showSummary
                    text: tile.summary
                    color: "#CDBFB4"
                    font.pixelSize: 14
                    wrapMode: Text.Wrap
                    lineHeight: 1.15
                }

                Item { Layout.fillHeight: true }

                CadenceLane {
                    phase: tile.phase
                    fps: tile.laneFps
                    tint: tile.active ? "#E4845E" : "#A08F84"
                }

                Label {
                    Layout.fillWidth: true
                    text: tile.result
                    color: tile.active ? "#E4845E" : "#A08F84"
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
            }
        }
    }

    // A track with a marker that crosses it. The marker only moves `fps` times a second, so
    // two lanes side by side show how much smoother a higher frame rate looks.
    component CadenceLane: Item {
        id: lane
        property real phase: 0
        property int fps: 30
        property color tint: "#A08F84"
        readonly property real steps: Math.max(1, 1.8 * fps)
        readonly property real shown: Math.floor(phase * steps) / steps
        Layout.fillWidth: true
        implicitHeight: 16
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 2
            radius: 1
            color: "#3B302B"
        }
        Rectangle {
            width: 16
            height: 16
            radius: 5
            color: lane.tint
            x: Math.round(lane.shown * (lane.width - width))
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // -------------------------------------------------------------- sidebar
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: consolePane.roomy ? 300 : 256
            color: consolePane.cSidebar

            Rectangle {
                anchors.right: parent.right
                width: 1
                height: parent.height
                color: consolePane.cBorder
            }

            ColumnLayout {
                anchors {
                    fill: parent
                    margins: 18
                }
                spacing: 4

                RowLayout {
                    Layout.bottomMargin: 22
                    Layout.topMargin: 6
                    Layout.leftMargin: 6
                    spacing: 12

                    Image {
                        source: "qrc:/icons/robzplay-kucuk.png"
                        sourceSize: Qt.size(46, 46)
                    }

                    ColumnLayout {
                        spacing: 0
                        Label {
                            text: "Robz Play"
                            font.family: consolePane.display
                            font.weight: Font.Black
                            font.italic: true
                            font.pixelSize: 27
                            color: consolePane.cText
                        }
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Remote Play with frame generation")
                            font.pixelSize: 12
                            color: consolePane.cFaint
                            elide: Text.ElideRight
                        }
                    }
                }

                NavButton {
                    text: qsTr("Add a console")
                    hint: "F2"
                    onClicked: root.showManualHostDialog()
                }

                NavButton {
                    text: qsTr("Refresh PSN hosts")
                    visible: Chiaki.settings.psnAuthToken ? true : false
                    onClicked: Chiaki.refreshPsnToken()
                }

                NavButton {
                    text: qsTr("Steam shortcut")
                    hint: "F1"
                    visible: typeof Chiaki.createSteamShortcut === "function"
                    onClicked: root.showSteamShortcutDialog(false)
                }

                NavButton {
                    id: settingsButton
                    text: qsTr("Settings")
                    onClicked: root.showSettingsDialog()
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    Layout.bottomMargin: 12
                    implicitHeight: 1
                    color: consolePane.cBorder
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 14
                    Layout.rightMargin: 10
                    spacing: 10
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Find consoles")
                            color: consolePane.cText
                            font.pixelSize: 16
                        }
                        Label {
                            text: Chiaki.discoveryEnabled ? qsTr("Searching your network") : qsTr("Search is off")
                            color: consolePane.cFaint
                            font.pixelSize: 12
                        }
                    }
                    Toggle {
                        on: Chiaki.discoveryEnabled
                        onClicked: Chiaki.discoveryEnabled = !Chiaki.discoveryEnabled
                    }
                }

                RowLayout {
                    visible: Chiaki.macOs
                    Layout.fillWidth: true
                    Layout.topMargin: 12
                    Layout.leftMargin: 14
                    Layout.rightMargin: 10
                    spacing: 10
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("macOS Wi-Fi Guard")
                            color: consolePane.cText
                            font.pixelSize: 15
                        }
                        Label {
                            Layout.fillWidth: true
                            text: Chiaki.awdlActive ? qsTr("Pause AirDrop/AWDL while streaming") : qsTr("AWDL paused (low-latency Wi-Fi)")
                            color: Chiaki.awdlActive ? consolePane.cWarn : consolePane.cGood
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }
                    Toggle {
                        on: Chiaki.settings.macAwdlGuardEnabled
                        onClicked: {
                            const next = !Chiaki.settings.macAwdlGuardEnabled;
                            Chiaki.settings.macAwdlGuardEnabled = next;
                            Chiaki.setAwdlSuppressed(next);
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 14
                    Layout.leftMargin: 14
                    Layout.rightMargin: 10
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Language")
                        color: consolePane.cText
                        font.pixelSize: 16
                    }
                    FlagButton {
                        code: "tr"
                        active: Chiaki.settings.language === "tr"
                        onClicked: Chiaki.settings.language = "tr"
                    }
                    FlagButton {
                        code: "en"
                        active: Chiaki.settings.language === "en"
                        onClicked: Chiaki.settings.language = "en"
                    }
                }

                Item { Layout.fillHeight: true }

                AbstractButton {
                    id: kickBadge
                    Layout.fillWidth: true
                    implicitHeight: 58
                    focusPolicy: Qt.NoFocus
                    hoverEnabled: true
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    onClicked: Qt.openUrlExternally("https://kick.com/robzsogood")
                    background: Rectangle {
                        radius: 12
                        color: kickBadge.hovered ? consolePane.cSurfaceHover : consolePane.cSurface
                        border.width: 1
                        border.color: kickBadge.hovered ? "#53FC18" : consolePane.cBorder
                    }
                    contentItem: RowLayout {
                        spacing: 12
                        Image {
                            Layout.leftMargin: 14
                            source: "qrc:/icons/kick.svg"
                            sourceSize: Qt.size(26, 26)
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Label {
                                Layout.fillWidth: true
                                text: "kick.com/robzsogood"
                                color: consolePane.cText
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                text: qsTr("Watch live on Kick")
                                color: consolePane.cFaint
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                AbstractButton {
                    id: discordBadge
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    implicitHeight: 58
                    focusPolicy: Qt.NoFocus
                    hoverEnabled: true
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    onClicked: Qt.openUrlExternally("https://discord.gg/UyyEn7SHm4")
                    background: Rectangle {
                        radius: 12
                        color: discordBadge.hovered ? consolePane.cSurfaceHover : consolePane.cSurface
                        border.width: 1
                        border.color: discordBadge.hovered ? "#5865F2" : consolePane.cBorder
                    }
                    contentItem: RowLayout {
                        spacing: 12
                        Image {
                            Layout.leftMargin: 14
                            source: "qrc:/icons/discord.svg"
                            sourceSize: Qt.size(26, 26)
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Label {
                                Layout.fillWidth: true
                                text: "discord.gg/UyyEn7SHm4"
                                color: consolePane.cText
                                // the whole address stays readable in the narrower sidebar too
                                font.pixelSize: consolePane.roomy ? 15 : 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                text: qsTr("Technical support on Discord")
                                color: consolePane.cFaint
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.topMargin: 10
                    Layout.leftMargin: 6
                    spacing: 8
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 0
                        spacing: 4
                        Label {
                            Layout.fillWidth: true
                            text: qsTr("Version %1").arg(Qt.application.version)
                            color: consolePane.cFaint
                            font.pixelSize: 12
                        }
                        // asks for a newer release now, and says how that went
                        AbstractButton {
                            id: checkUpdatesLink
                            visible: !Chiaki.updater.available
                            enabled: Chiaki.updater.state !== "checking"
                            Layout.fillWidth: true
                            implicitHeight: checkUpdatesLabel.implicitHeight
                            focusPolicy: Qt.NoFocus
                            hoverEnabled: true
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            onClicked: {
                                consolePane.updateCheckNote = "";
                                Chiaki.updater.checkNow();
                            }
                            background: Item {}
                            contentItem: Label {
                                id: checkUpdatesLabel
                                text: {
                                    if (Chiaki.updater.state === "checking")
                                        return qsTr("Checking…");
                                    if (consolePane.updateCheckNote === "uptodate")
                                        return qsTr("Robz Play is up to date");
                                    if (consolePane.updateCheckNote === "failed")
                                        return qsTr("Could not check. Is the internet connected?");
                                    return qsTr("Check for updates");
                                }
                                color: consolePane.updateCheckNote === "failed" ? consolePane.cWarn
                                    : (consolePane.updateCheckNote === "uptodate" ? consolePane.cGood
                                    : (checkUpdatesLink.hovered ? consolePane.cText : consolePane.cMuted))
                                font.pixelSize: 12
                                font.underline: consolePane.updateCheckNote === "" && Chiaki.updater.state !== "checking"
                                wrapMode: Text.Wrap
                            }
                        }

                        // a newer release that is waiting: opens its notes again
                        AbstractButton {
                            id: updateBadge
                            visible: Chiaki.updater.available
                            implicitHeight: 24
                            implicitWidth: updateBadgeLabel.implicitWidth + 20
                            focusPolicy: Qt.NoFocus
                            hoverEnabled: true
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            onClicked: updatePopup.open()
                            background: RobzButtonBg {
                                id: updateBadgeBg
                                radius: 12
                                hovered: updateBadge.hovered
                                pressed: updateBadge.pressed
                            }
                            contentItem: Label {
                                id: updateBadgeLabel
                                text: qsTr("Update available: %1").arg(Chiaki.updater.latestVersion)
                                color: updateBadgeBg.textColor
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }
                    CardAction {
                        text: qsTr("Quit")
                        onClicked: Qt.quit()
                    }
                }
            }
        }

        // -------------------------------------------------------------- content
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // the floor of the icon's sunset along the bottom: a city on the horizon and a grid
            // running towards it (decoration only; the cards stand in front of it)
            Image {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: Math.min(parent.height * 0.34, 260)
                source: "qrc:/icons/robz-zemin.png"
                fillMode: Image.PreserveAspectCrop
                verticalAlignment: Image.AlignBottom
                smooth: true
                opacity: 0.5
            }

            ColumnLayout {
                id: contentRow
                anchors {
                    fill: parent
                    leftMargin: consolePane.roomy ? 36 : 24
                    rightMargin: consolePane.roomy ? 36 : 24
                    topMargin: 30
                    bottomMargin: 26
                }
                spacing: 20

                // ------------------------------------------------------ consoles
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 18

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Label {
                            text: qsTr("Consoles")
                            font.family: consolePane.display
                            font.weight: Font.Black
                            font.italic: true
                            font.pixelSize: 36
                            color: consolePane.cText
                        }
                        Label {
                            Layout.fillWidth: true
                            text: {
                                if (consolePane.visibleHosts === 0)
                                    return Chiaki.discoveryEnabled ? qsTr("Looking for PlayStation consoles on your network…") : qsTr("Console search is switched off.");
                                if (consolePane.hostsToSetUp > 0)
                                    return qsTr("Choose Set up, then type the code the console shows under Settings › System › Remote Play › Link Device.");
                                return qsTr("Choose a console to start playing.");
                            }
                            color: consolePane.cMuted
                            font.pixelSize: 16
                            wrapMode: Text.Wrap
                        }
                    }

                    Item {
                        // as tall as what it shows; it gives way and scrolls when the window is short
                        readonly property real wanted: Math.max(164, consolePane.visibleHosts === 0 ? connectSteps.implicitHeight + 8 : hostsView.contentHeight)
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 164
                        Layout.preferredHeight: wanted
                        Layout.maximumHeight: wanted
                        clip: true

                        ListView {
                            id: hostsView
                            keyNavigationWraps: true
                            anchors.fill: parent
                            clip: true
                            visible: !consolePane.previewEmpty
                            model: Chiaki.hosts
                            onCountChanged: {
                                if(!hostsView.currentItem)
                                    hostsView.incrementCurrentIndex();
                                if(!hostsView.currentItem)
                                    return;
                                if(!hostsView.currentItem.visible)
                                {
                                    for(var i = 0; i < hostsView.count; i++)
                                    {
                                        hostsView.incrementCurrentIndex()
                                        if(hostsView.currentItem.visible)
                                        {
                                            break;
                                        }
                                    }
                                }
                            }
                            delegate: ItemDelegate {
                                id: delegate
                                visible: modelData.display
                                width: parent ? parent.width : 0
                                height: modelData.display ? 178 : 0
                                padding: 0
                                highlighted: ListView.isCurrentItem
                                onClicked: connectToHost()
                                HoverHandler { cursorShape: Qt.PointingHandCursor }

                                function connectToHost() {
                                    // a changed setting is waiting for a restart: do not start a stream on the old one
                                    if (root.restartPending) {
                                        root.askRestart();
                                        return;
                                    }
                                    if(modelData.discovered)
                                        Chiaki.connectToHost(index, modelData.name);
                                    else
                                        Chiaki.connectToHost(index);
                                }

                                function wakeUpHost() {
                                    if(!modelData.discovered && !modelData.duid)
                                        Chiaki.wakeUpHost(index);
                                }

                                function deleteHost() {
                                    if (modelData.manual)
                                        root.showConfirmDialog(qsTr("Delete Console"), qsTr("Are you sure you want to delete this console?"), () => {Chiaki.deleteHost(index)});

                                    else if (modelData.discovered && !modelData.registered)
                                        root.showConfirmDialog(qsTr("Hide Console"), qsTr("Are you sure you want to hide this console?") + "\n\n" + qsTr("Note: You can unhide from the Consoles section of the Settings under Hidden Consoles"), () => Chiaki.hideHost(modelData.mac, modelData.name));

                                }

                                function setConsolePin() {
                                    root.showConsolePinDialog(index);
                                }

                                readonly property bool standby: modelData.state == "standby"
                                readonly property bool usable: (modelData.registered || modelData.duid) ? true : false
                                readonly property color stateColor: {
                                    if (!usable)
                                        return consolePane.cAccent;
                                    if (modelData.state == "ready")
                                        return consolePane.cGood;
                                    return standby ? consolePane.cWarn : consolePane.cFaint;
                                }

                                // where the console stands, in plain words
                                readonly property string statusText: {
                                    if (modelData.duid)
                                        return modelData.discovered ? qsTr("Automatic registration available") : qsTr("Remote connection via PSN");
                                    if (modelData.state == "ready")
                                        return modelData.registered ? qsTr("On and ready to play") : qsTr("On, not set up yet");
                                    if (standby)
                                        return modelData.registered ? qsTr("In rest mode. Play wakes it up; if it does not, press the PS button.") : qsTr("In rest mode, not set up yet");
                                    return modelData.registered ? qsTr("Not seen on your network right now") : qsTr("Not set up yet");
                                }

                                // the facts about it, for those who need them
                                readonly property string detailText: {
                                    let parts = [];
                                    if (modelData.address)
                                        parts.push(qsTr("Address %1").arg(Chiaki.settings.streamerMode ? qsTr("hidden") : modelData.address));
                                    if (modelData.mac)
                                        parts.push(qsTr("ID %1").arg(Chiaki.settings.streamerMode ? qsTr("hidden") : modelData.mac));
                                    if (!modelData.duid) {
                                        if (modelData.discovered)
                                            parts.push(modelData.manual ? qsTr("Found on your network, also added by address") : qsTr("Found on your network"));
                                        else
                                            parts.push(qsTr("Added by address"));
                                        if (modelData.discovered) {
                                            if (modelData.app)
                                                parts.push(qsTr("Running %1").arg(modelData.app));
                                            if (modelData.titleId)
                                                parts.push(qsTr("Title ID %1").arg(modelData.titleId));
                                        }
                                    }
                                    return parts.join("     ");
                                }

                                background: Item {
                                    Rectangle {
                                        anchors {
                                            fill: parent
                                            bottomMargin: 14
                                        }
                                        radius: 16
                                        color: delegate.hovered ? consolePane.cSurfaceHover : consolePane.cSurface
                                        border.width: delegate.highlighted ? 2 : 1
                                        border.color: delegate.highlighted ? consolePane.cAccent : consolePane.cBorder
                                    }
                                }

                                contentItem: Item {
                                    RowLayout {
                                        anchors {
                                            fill: parent
                                            leftMargin: 22
                                            rightMargin: 22
                                            topMargin: 14
                                            bottomMargin: 28
                                        }
                                        spacing: 22

                                        Image {
                                            Layout.fillHeight: true
                                            Layout.preferredWidth: consolePane.roomy ? 112 : 84
                                            fillMode: Image.PreserveAspectFit
                                            source: "image://svg/console-ps" + (modelData.ps5 ? "5" : "4") + (delegate.standby ? "#light_standby" : "#light_on")
                                            sourceSize: Qt.size(width, height)
                                        }

                                        ColumnLayout {
                                            Layout.alignment: Qt.AlignVCenter
                                            Layout.fillWidth: true
                                            spacing: 5

                                            Label {
                                                Layout.fillWidth: true
                                                text: modelData.name ? modelData.name : (modelData.ps5 ? "PlayStation 5" : "PlayStation 4")
                                                color: consolePane.cText
                                                font.pixelSize: 23
                                                font.weight: Font.DemiBold
                                                elide: Text.ElideRight
                                            }

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: 9
                                                Rectangle {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    implicitWidth: 9
                                                    implicitHeight: 9
                                                    radius: 4.5
                                                    color: delegate.stateColor
                                                }
                                                Label {
                                                    Layout.fillWidth: true
                                                    text: delegate.statusText
                                                    color: consolePane.cMuted
                                                    font.pixelSize: 15
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            Label {
                                                Layout.fillWidth: true
                                                text: delegate.detailText
                                                color: consolePane.cFaint
                                                font.pixelSize: 13
                                                elide: Text.ElideRight
                                            }

                                            RowLayout {
                                                Layout.topMargin: 5
                                                spacing: 8

                                                CardAction {
                                                    text: qsTr("Wake Up")
                                                    visible: modelData.registered && !modelData.duid && !modelData.discovered
                                                    glyph: root.controllerButton("pyramid")
                                                    showGlyph: delegate.highlighted
                                                    onClicked: delegate.wakeUpHost()
                                                }

                                                CardAction {
                                                    text: qsTr("Console PIN")
                                                    visible: modelData.registered
                                                    glyph: "qrc:/icons/l1.svg"
                                                    showGlyph: delegate.highlighted
                                                    onClicked: delegate.setConsolePin()
                                                }

                                                CardAction {
                                                    text: modelData.manual ? qsTr("Delete") : qsTr("Hide")
                                                    visible: modelData.manual || (modelData.discovered && !modelData.registered)
                                                    glyph: root.controllerButton("box")
                                                    showGlyph: delegate.highlighted
                                                    onClicked: delegate.deleteHost()
                                                }
                                            }
                                        }

                                        AbstractButton {
                                            id: playButton
                                            Layout.alignment: Qt.AlignVCenter
                                            implicitHeight: 50
                                            implicitWidth: Math.max(128, playLabel.implicitWidth + 52)
                                            focusPolicy: Qt.NoFocus
                                            hoverEnabled: true
                                            onClicked: delegate.connectToHost()
                                            background: RobzButtonBg {
                                                id: playBg
                                                radius: 12
                                                hovered: playButton.hovered
                                                pressed: playButton.pressed
                                            }
                                            contentItem: Label {
                                                id: playLabel
                                                text: delegate.usable ? qsTr("Play") : qsTr("Set up")
                                                color: playBg.textColor
                                                font.pixelSize: 18
                                                font.family: consolePane.display
                                                font.weight: Font.Black
                                                font.italic: true
                                                horizontalAlignment: Text.AlignHCenter
                                                verticalAlignment: Text.AlignVCenter
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // nothing to show yet: the three steps that get a console on this screen
                        ColumnLayout {
                            id: connectSteps
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                topMargin: 6
                            }
                            visible: consolePane.visibleHosts === 0
                            spacing: 16

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: stepsColumn.implicitHeight + 52
                                radius: 16
                                color: consolePane.cSurface
                                border.color: consolePane.cBorder

                                ColumnLayout {
                                    id: stepsColumn
                                    anchors {
                                        left: parent.left
                                        right: parent.right
                                        top: parent.top
                                        margins: 26
                                    }
                                    spacing: 16

                                    Label {
                                        Layout.fillWidth: true
                                        text: qsTr("Connect your PlayStation")
                                        font.family: consolePane.display
                                        font.weight: Font.Black
                                        font.italic: true
                                        font.pixelSize: 25
                                        color: consolePane.cText
                                    }

                                    Repeater {
                                        model: [
                                            // first the users (a single one can send Remote Play back to
                                            // the console's home screen), then Remote Play on each of them
                                            qsTr("On the PS5, add a second, empty user (profile icon › Switch User › Add User) and remove your profile's login passcode if it has one. With a single user the console can send Remote Play back to its home screen. When it asks who plays, choose the second profile (or the main one if a controller is connected to this PC)."),
                                            qsTr("Then switch on Remote Play on every profile: Settings › System › Remote Play › Enable Remote Play."),
                                            qsTr("Keep the PS5 and this PC on the same network. A cable gives the steadiest picture."),
                                            qsTr("The console then shows up here by itself. Choose Set up and type the code the PS5 shows under Link Device.")
                                        ]

                                        RowLayout {
                                            id: stepRow
                                            required property int index
                                            required property string modelData
                                            Layout.fillWidth: true
                                            spacing: 14

                                            // a little tile filled like the letters of the icon
                                            RobzButtonBg {
                                                id: stepTile
                                                Layout.alignment: Qt.AlignTop
                                                implicitWidth: 32
                                                implicitHeight: 32
                                                radius: 9
                                                Label {
                                                    anchors.centerIn: parent
                                                    text: stepRow.index + 1
                                                    color: stepTile.textColor
                                                    font.pixelSize: 16
                                                    font.family: consolePane.display
                                                    font.weight: Font.Black
                                                    font.italic: true
                                                }
                                            }

                                            Label {
                                                Layout.fillWidth: true
                                                Layout.topMargin: 4
                                                text: stepRow.modelData
                                                color: consolePane.cMuted
                                                font.pixelSize: 16
                                                wrapMode: Text.Wrap
                                                lineHeight: 1.15
                                            }
                                        }
                                    }

                                    CardAction {
                                        Layout.topMargin: 2
                                        Layout.leftMargin: 44
                                        text: qsTr("Add a console by address")
                                        onClicked: root.showManualHostDialog()
                                    }
                                }
                            }
                        }
                    }
                }

                // ------------------------------------------------------ picture mode
                // What Robz Play offers, as one choice in the middle of the screen: the plain
                // Remote Play stream, or that stream with frames generated in between. The
                // three tiles write the same two settings the Settings page shows
                // (frame generation on/off and its target).
                Rectangle {
                    id: modePanel
                    Layout.fillWidth: true
                    implicitHeight: modeColumn.implicitHeight + (consolePane.tall ? 44 : 30)
                    // with no console yet, the steps that get one come first: the panel shows
                    // only where the window has room for both (the title above takes ~130 px)
                    visible: consolePane.visibleHosts > 0
                             || (consolePane.tall && contentRow.height >= connectSteps.implicitHeight + implicitHeight + 130)
                    radius: 16
                    color: consolePane.cSurface
                    border.color: consolePane.cBorder

                    ColumnLayout {
                        id: modeColumn
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 22
                            topMargin: consolePane.tall ? 22 : 15
                        }
                        spacing: consolePane.tall ? 14 : 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 14

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Label {
                                    text: qsTr("Picture mode")
                                    font.family: consolePane.display
                                    font.weight: Font.Black
                                    font.italic: true
                                    font.pixelSize: 24
                                    color: consolePane.cText
                                }
                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("Choose how Robz Play shows the stream. It applies from the next connection.")
                                    color: consolePane.cMuted
                                    font.pixelSize: 14
                                    wrapMode: Text.Wrap
                                }
                            }

                            Label {
                                Layout.alignment: Qt.AlignVCenter
                                text: qsTr("Stream: %1, %2 FPS").arg(consolePane.streamResolution).arg(Chiaki.settings.fpsLocalPS5)
                                color: consolePane.cMuted
                                font.pixelSize: 14
                            }

                            CardAction {
                                Layout.alignment: Qt.AlignVCenter
                                text: qsTr("Stream settings")
                                onClicked: root.showSettingsDialog(2)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            uniformCellSizes: true

                            ModeTile {
                                title: qsTr("Stream only")
                                summary: qsTr("Plain Remote Play: the picture exactly as the console sends it. Frame generation is off.")
                                result: qsTr("A 30 FPS game stays at 30 FPS")
                                laneFps: 30
                                showSummary: consolePane.tall
                                phase: consolePane.cadencePhase
                                active: !Chiaki.settings.frameGenEnabled
                                onClicked: Chiaki.settings.frameGenEnabled = false
                            }

                            ModeTile {
                                title: qsTr("60 FPS")
                                badge: qsTr("For GTA VI")
                                badgeTint: "#E4845E"
                                summary: qsTr("This PC's graphics card draws the frames in between, so a 30 FPS game looks like 60.")
                                result: qsTr("A 30 FPS game is shown at 60 FPS")
                                laneFps: 60
                                showSummary: consolePane.tall
                                phase: consolePane.cadencePhase
                                active: Chiaki.settings.frameGenEnabled && Chiaki.settings.frameGenTargetFps === 60
                                onClicked: {
                                    Chiaki.settings.frameGenTargetFps = 60;
                                    Chiaki.settings.frameGenEnabled = true;
                                }
                            }

                            ModeTile {
                                title: qsTr("120 FPS")
                                badge: qsTr("Experimental")
                                summary: qsTr("Three generated frames between every two real ones. Needs a fast graphics card and a 120 Hz screen.")
                                result: qsTr("A 30 FPS game is shown at 120 FPS")
                                laneFps: 120
                                showSummary: consolePane.tall
                                phase: consolePane.cadencePhase
                                active: Chiaki.settings.frameGenEnabled && Chiaki.settings.frameGenTargetFps === 120
                                onClicked: {
                                    Chiaki.settings.frameGenTargetFps = 120;
                                    Chiaki.settings.frameGenEnabled = true;
                                }
                            }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            columns: consolePane.roomy ? 4 : 2
                            columnSpacing: 26
                            rowSpacing: 12

                            // the two that only matter while frames are generated
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                opacity: Chiaki.settings.frameGenEnabled ? 1.0 : 0.4
                                enabled: Chiaki.settings.frameGenEnabled
                                Label { text: qsTr("Motion detail"); color: consolePane.cMuted; font.pixelSize: 14 }
                                SegmentGroup {
                                    Segment {
                                        text: qsTr("Auto")
                                        active: Chiaki.settings.frameGenFlowDivisor === 0
                                        onClicked: Chiaki.settings.frameGenFlowDivisor = 0
                                    }
                                    Segment {
                                        text: qsTr("Fast")
                                        active: Chiaki.settings.frameGenFlowDivisor === 4
                                        onClicked: Chiaki.settings.frameGenFlowDivisor = 4
                                    }
                                    Segment {
                                        text: qsTr("Perf")
                                        active: Chiaki.settings.frameGenFlowDivisor === 3
                                        onClicked: Chiaki.settings.frameGenFlowDivisor = 3
                                    }
                                    Segment {
                                        text: qsTr("Balanced")
                                        active: Chiaki.settings.frameGenFlowDivisor === 2
                                        onClicked: Chiaki.settings.frameGenFlowDivisor = 2
                                    }
                                    Segment {
                                        text: qsTr("High")
                                        active: Chiaki.settings.frameGenFlowDivisor === 1
                                        onClicked: Chiaki.settings.frameGenFlowDivisor = 1
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignBottom
                                Layout.minimumHeight: 40
                                spacing: 12
                                opacity: Chiaki.settings.frameGenEnabled ? 1.0 : 0.4
                                enabled: Chiaki.settings.frameGenEnabled
                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("Keep HUD and text steady")
                                    color: consolePane.cMuted
                                    font.pixelSize: 14
                                    wrapMode: Text.Wrap
                                }
                                Toggle {
                                    on: Chiaki.settings.frameGenProtectStatic
                                    onClicked: Chiaki.settings.frameGenProtectStatic = !Chiaki.settings.frameGenProtectStatic
                                }
                            }

                            // the two that apply to every stream
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Label { text: qsTr("Sharpening"); color: consolePane.cMuted; font.pixelSize: 14 }
                                SegmentGroup {
                                    Segment {
                                        text: qsTr("Off")
                                        active: Chiaki.settings.sharpening === 0
                                        onClicked: Chiaki.settings.sharpening = 0
                                    }
                                    Segment {
                                        text: qsTr("Low")
                                        active: Chiaki.settings.sharpening === 1
                                        onClicked: Chiaki.settings.sharpening = 1
                                    }
                                    Segment {
                                        text: qsTr("Medium")
                                        active: Chiaki.settings.sharpening === 2
                                        onClicked: Chiaki.settings.sharpening = 2
                                    }
                                    Segment {
                                        text: qsTr("High")
                                        active: Chiaki.settings.sharpening === 3
                                        onClicked: Chiaki.settings.sharpening = 3
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignBottom
                                Layout.minimumHeight: 40
                                spacing: 12
                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("Show an FPS counter while playing")
                                    color: consolePane.cMuted
                                    font.pixelSize: 14
                                    wrapMode: Text.Wrap
                                }
                                Toggle {
                                    on: Chiaki.settings.showFpsCounter
                                    onClicked: Chiaki.settings.showFpsCounter = !Chiaki.settings.showFpsCounter
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.columnSpan: consolePane.roomy ? 2 : 2
                                spacing: 6
                                Label { text: qsTr("Image Enhancement Tech"); color: consolePane.cMuted; font.pixelSize: 14 }
                                SegmentGroup {
                                    Segment {
                                        text: qsTr("Off")
                                        active: Chiaki.settings.pictureEnhanceMode === 0
                                        onClicked: Chiaki.settings.pictureEnhanceMode = 0
                                    }
                                    Segment {
                                        text: qsTr("Adaptive")
                                        active: Chiaki.settings.pictureEnhanceMode === 1
                                        onClicked: Chiaki.settings.pictureEnhanceMode = 1
                                    }
                                    Segment {
                                        text: qsTr("AMD CAS")
                                        active: Chiaki.settings.pictureEnhanceMode === 2
                                        onClicked: Chiaki.settings.pictureEnhanceMode = 2
                                    }
                                    Segment {
                                        text: qsTr("Cinema")
                                        active: Chiaki.settings.pictureEnhanceMode === 3
                                        onClicked: Chiaki.settings.pictureEnhanceMode = 3
                                    }
                                    Segment {
                                        text: qsTr("Ultra Crisp")
                                        active: Chiaki.settings.pictureEnhanceMode === 4
                                        onClicked: Chiaki.settings.pictureEnhanceMode = 4
                                    }
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Label { text: qsTr("Color Vibrance & Clarity"); color: consolePane.cMuted; font.pixelSize: 14 }
                                SegmentGroup {
                                    Segment {
                                        text: qsTr("Off")
                                        active: Chiaki.settings.vibranceLevel === 0
                                        onClicked: Chiaki.settings.vibranceLevel = 0
                                    }
                                    Segment {
                                        text: qsTr("Subtle")
                                        active: Chiaki.settings.vibranceLevel === 1
                                        onClicked: Chiaki.settings.vibranceLevel = 1
                                    }
                                    Segment {
                                        text: qsTr("Vivid")
                                        active: Chiaki.settings.vibranceLevel === 2
                                        onClicked: Chiaki.settings.vibranceLevel = 2
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignBottom
                                Layout.minimumHeight: 40
                                spacing: 12
                                Label {
                                    Layout.fillWidth: true
                                    text: qsTr("Deband smooth gradients")
                                    color: consolePane.cMuted
                                    font.pixelSize: 14
                                    wrapMode: Text.Wrap
                                }
                                Toggle {
                                    on: Chiaki.settings.debandQuickEnabled
                                    onClicked: Chiaki.settings.debandQuickEnabled = !Chiaki.settings.debandQuickEnabled
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }
    }

    // ------------------------------------------------------------------ update
    // A newer release is offered once per version and run of the application, and only here
    // on the home screen - never in the middle of a game.
    function offerUpdate() {
        if (!Chiaki.updater.available || updatePopup.opened)
            return;
        if (root.updateOfferedVersion === Chiaki.updater.latestVersion)
            return;
        if (consolePane.StackView.status !== StackView.Active)
            return;
        root.updateOfferedVersion = Chiaki.updater.latestVersion;
        updatePopup.open();
    }

    // a moment after the home screen shows, so it does not collide with the start-up questions
    Timer {
        id: updateOfferTimer
        interval: 1500
        onTriggered: consolePane.offerUpdate()
    }

    Connections {
        target: Chiaki.updater
        function onOffered() { updateOfferTimer.restart(); }
        function onManualResult(result) {
            if (result === "available") {
                consolePane.updateCheckNote = "";
                root.updateOfferedVersion = Chiaki.updater.latestVersion;
                updatePopup.open();
                return;
            }
            consolePane.updateCheckNote = result;
            updateCheckNoteTimer.restart();
        }
    }

    // what the last check asked for by the user found, shown under the version for a while
    property string updateCheckNote: ""
    Timer {
        id: updateCheckNoteTimer
        interval: 6000
        onTriggered: consolePane.updateCheckNote = ""
    }

    Popup {
        id: updatePopup
        readonly property bool busy: Chiaki.updater.state === "downloading" || Chiaki.updater.state === "starting"
        // centred on the application window, the same way the other dialogs are: the overlay's
        // own size can still be that of the minimised window the popup was opened in
        parent: Overlay.overlay
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: Math.max(420, Math.min(700, root.width - 64))
        height: Math.max(300, Math.min(updateColumn.implicitHeight + 2 * padding, root.height - 64))
        padding: 30
        modal: true
        focus: true
        closePolicy: busy ? Popup.NoAutoClose : (Popup.CloseOnEscape | Popup.CloseOnPressOutside)
        onOpened: updateColumn.forceActiveFocus(Qt.TabFocusReason)
        onClosed: consolePane.forceActiveFocus(Qt.TabFocusReason)

        Overlay.modal: Rectangle { color: "#A6000000" }
        background: Rectangle {
            radius: 18
            color: "#1D1816"
            border.color: "#3B302B"
        }

        contentItem: ColumnLayout {
            id: updateColumn
            spacing: 16
            Keys.onReturnPressed: if (!updatePopup.busy) Chiaki.updater.install()
            Keys.onEscapePressed: {
                if (Chiaki.updater.state === "downloading")
                    Chiaki.updater.cancel();
                else if (!updatePopup.busy)
                    updatePopup.close();
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 16
                Image {
                    source: "qrc:/icons/robzplay-kucuk.png"
                    sourceSize: Qt.size(52, 52)
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("New version: %1").arg(Chiaki.updater.latestVersion)
                        font.family: consolePane.display
                        font.weight: Font.Black
                        font.italic: true
                        font.pixelSize: 28
                        color: consolePane.cText
                        elide: Text.ElideRight
                    }
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("You are using %1").arg(Chiaki.updater.currentVersion)
                        font.pixelSize: 15
                        color: consolePane.cMuted
                    }
                }
            }

            Label {
                text: qsTr("What's new")
                font.pixelSize: 15
                font.weight: Font.DemiBold
                color: consolePane.cMuted
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Math.min(notesText.implicitHeight + 32, 320)
                Layout.minimumHeight: 80
                radius: 12
                color: consolePane.cInset
                border.color: consolePane.cBorder

                Flickable {
                    id: notesFlick
                    anchors {
                        fill: parent
                        margins: 16
                    }
                    clip: true
                    contentWidth: width
                    contentHeight: notesText.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: notesFlick.contentHeight > notesFlick.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff }

                    Text {
                        id: notesText
                        width: notesFlick.width - 12
                        text: Chiaki.updater.notes
                        textFormat: Text.MarkdownText
                        wrapMode: Text.Wrap
                        color: consolePane.cText
                        linkColor: consolePane.cAccent
                        font.pixelSize: 15
                        lineHeight: 1.2
                        onLinkActivated: (link) => Qt.openUrlExternally(link)
                    }
                }
            }

            // the download, while it runs
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: updatePopup.busy
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 8
                    radius: 4
                    color: consolePane.cInset
                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, Chiaki.updater.progress))
                        height: parent.height
                        radius: 4
                        color: consolePane.cAccent
                    }
                }
                Label {
                    text: Chiaki.updater.state === "starting"
                        ? qsTr("Starting the installer…")
                        : qsTr("Downloading %1 of %2 MB").arg(Chiaki.updater.downloadedMb.toFixed(0)).arg(Chiaki.updater.sizeMb.toFixed(0))
                    font.pixelSize: 14
                    color: consolePane.cMuted
                }
            }

            Label {
                Layout.fillWidth: true
                visible: Chiaki.updater.state === "error"
                text: Chiaki.updater.errorText
                color: consolePane.cWarn
                font.pixelSize: 14
                wrapMode: Text.Wrap
            }

            Label {
                Layout.fillWidth: true
                visible: !updatePopup.busy
                text: qsTr("Updating closes Robz Play, installs the new version and opens it again. Your settings and consoles are kept.")
                color: consolePane.cFaint
                font.pixelSize: 13
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 10

                CardAction {
                    visible: !updatePopup.busy
                    text: qsTr("Open the release page")
                    onClicked: Qt.openUrlExternally(Chiaki.updater.releaseUrl)
                }
                Item { Layout.fillWidth: true }
                CardAction {
                    visible: !updatePopup.busy
                    text: qsTr("Skip this version")
                    onClicked: {
                        Chiaki.updater.skip();
                        updatePopup.close();
                    }
                }
                CardAction {
                    visible: !updatePopup.busy
                    text: qsTr("Later")
                    onClicked: updatePopup.close()
                }
                CardAction {
                    visible: Chiaki.updater.state === "downloading"
                    text: qsTr("Cancel")
                    onClicked: Chiaki.updater.cancel()
                }
                AbstractButton {
                    id: updateNowButton
                    implicitHeight: 44
                    implicitWidth: Math.max(160, updateNowLabel.implicitWidth + 44)
                    enabled: !updatePopup.busy
                    opacity: enabled ? 1.0 : 0.5
                    focusPolicy: Qt.NoFocus
                    hoverEnabled: true
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    onClicked: Chiaki.updater.install()
                    background: RobzButtonBg {
                        id: updateNowBg
                        radius: 10
                        hovered: updateNowButton.hovered
                        pressed: updateNowButton.pressed
                    }
                    contentItem: Label {
                        id: updateNowLabel
                        text: qsTr("Update now")
                        color: updateNowBg.textColor
                        font.pixelSize: 17
                        font.family: consolePane.display
                        font.weight: Font.Black
                        font.italic: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}

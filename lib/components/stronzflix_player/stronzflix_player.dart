import 'dart:async';

import 'package:cast/cast.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:stronzflix/backend/api/media.dart';
import 'package:stronzflix/backend/backend.dart';
import 'package:stronzflix/backend/peer_manager.dart';
import 'package:stronzflix/components/stronzflix_player/animated_play_pause.dart';
import 'package:stronzflix/components/stronzflix_player/chat_drawer.dart';
import 'package:stronzflix/components/stronzflix_player/control_widget.dart';
import 'package:stronzflix/components/stronzflix_player/stronzflix_player_controller.dart';
import 'package:stronzflix/components/stronzflix_player/stronzflix_player_progress_bar.dart';
import 'package:stronzflix/components/stronzflix_player/stronzflix_player_sinks.dart';
import 'package:stronzflix/utils/format.dart';
import 'package:stronzflix/utils/platform.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';

class StronzflixPlayer extends StatefulWidget {
  
    final Watchable media;

    const StronzflixPlayer({super.key, required this.media});

    @override
    State<StronzflixPlayer> createState() => _StronzflixPlayerState();
}

class _StronzflixPlayerState extends State<StronzflixPlayer> {

    StronzflixPlayerController? _controller;
    late StronzflixPlayerSinks _sink;

    late CastDevice _castDevice;

    late FocusScopeNode _focusNode;
    late Future<List<CastDevice>> _castDiscovery;

    late bool _fullscreen;
    late bool _chatOpened;

    late Timer _hideTimer;
    late bool _hideControls;
    late bool _permanetlyShowControls;

    late Duration _startAt;

    Future<void> _initLocalPlayer() async {
        Uri uri = await super.widget.media.player.getSource(super.widget.media);
        uri = Uri.parse(uri.toString().split('?').join('.m3u8?'));
        this._controller?.dispose();
        this._controller = LocalPlayerController(VideoPlayerController.networkUrl(uri));
        await this._controller!.initialize();
        this._controller!.addListener(this._updateState);
        this._controller!.seekTo(this._startAt);
        this._permanetlyShowControls = false;
    }

    Future<void> _initCastPlayer() async {
        Uri uri = await super.widget.media.player.getSource(super.widget.media);
        uri = Uri.parse(uri.toString().split('?').join('.m3u8?'));
        this._controller?.dispose();
        this._controller = CastPlayerController(uri, this._castDevice);
        await this._controller!.initialize();
        this._controller!.addListener(this._updateState);
        this._controller!.seekTo(this._startAt);
        this._permanetlyShowControls = true;
    }

    @override
    void initState() {
        super.initState();
        this._sink = StronzflixPlayerSinks.local;

        this._focusNode = FocusScopeNode();
        this._castDiscovery = CastDiscoveryService().search();
    
        this._startAt = Duration(milliseconds: super.widget.media.startAt);

        this._chatOpened = false;
        this._fullscreen = false;
        this._hideControls = false;
        this._permanetlyShowControls = false;

        this._startHideTimer();

        PeerManager.registerHandler(PeerMessageIntent.seek,
            (at) => this.onSeek(Duration(milliseconds: at["time"]), peer: false)
        );

        PeerManager.registerHandler(PeerMessageIntent.pause,
            (_) {
                if(this._controller?.isPlaying ?? false)
                    this._onPlayPause(peer: false);
            }
        );

        PeerManager.registerHandler(PeerMessageIntent.play,
            (_) {
                if(!(this._controller?.isPlaying ?? false))
                    this._onPlayPause(peer: false);
            }
        );
    }

    @override
    void dispose() {
        this._cancelHideTimer();
        this._controller?.removeListener(this._updateState);
        this._controller?.dispose();
        Backend.updateWatching(super.widget.media, this._controller?.position.inMilliseconds ?? 0);
        super.dispose();
    }

    Widget _buildLocalPlayer(BuildContext context) {
        Widget build(LocalPlayerController controller) {
            return AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller.controller),
            ); 
        }

        return Center(
            child: this._controller is LocalPlayerController ?
                build(this._controller as LocalPlayerController) :
                FutureBuilder(
                future: this._initLocalPlayer(),
                builder: (context, snapshot) {
                    if(snapshot.connectionState != ConnectionState.done)
                        return const CircularProgressIndicator();
                    return build(this._controller as LocalPlayerController);
                }
            )
        );
    }

    Widget _buildCastPlayer(BuildContext context) {
        Widget build(CastPlayerController controller) {
            return const Icon(
                Icons.cast,
                size: 100,
            );
        }

        return Center(
            child: this._controller is CastPlayerController ?
                build(this._controller as CastPlayerController) :
                FutureBuilder(
                    future: this._initCastPlayer(),
                    builder: (context, snapshot) {
                        if(snapshot.connectionState != ConnectionState.done)
                            return const CircularProgressIndicator();
                        return build(this._controller as CastPlayerController);
                    }
                )
        );
    }

    Widget _buildTitle(BuildContext context) {
        late String title;
        if (super.widget.media is Film) {
            title = (super.widget.media as Film).name;
        }
        else if (super.widget.media is Episode) {
            Episode ep = super.widget.media as Episode;
            title = "${ep.series.name} - ${ep.name}";
        } else
            throw Exception("Unknown media type");

        return ControlWidget(
            hidden: this._hideControls,
            child: Text(title)
        );
    }

    Widget _buildBackButton(BuildContext context) {
        return ControlWidget(
            hidden: this._hideControls,
            onEnter: (_) => this._cancelHideTimer(),
            onExit: (_) => this._restartHideTimer(),
            child: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                    if(this._fullscreen)
                        this._onExpandCollapse();
                    PeerManager.stopWatching();
                    Navigator.of(context).pop();
                }
            )
        );
    }

    Widget _buildCastButton(BuildContext context) {
        Widget build() {
            if(this._sink == StronzflixPlayerSinks.local)
                return FutureBuilder(
                    future: this._castDiscovery,
                    builder: (context, snapshot) {
                        if(!snapshot.hasData || snapshot.data!.isEmpty)
                            return const SizedBox();

                        return PopupMenuButton(
                            icon: const Icon(Icons.cast),
                            position: PopupMenuPosition.under,
                            itemBuilder: (context) => snapshot.data!.map((e) => PopupMenuItem(
                                value: e,
                                child: Text(e.name),
                            )).toList(),
                            onSelected: (value) => super.setState(() {
                                this._castDevice = value;
                                this._startAt = this._controller?.position ?? Duration.zero;
                                this._sink = StronzflixPlayerSinks.cast;

                                if(this._fullscreen)
                                    this._onExpandCollapse();         
                            })
                        );
                    }
                );

            if(this._sink == StronzflixPlayerSinks.cast)
                return IconButton(
                    icon: const Icon(Icons.cast_connected),
                    onPressed: () => super.setState(() {
                        this._startAt = this._controller?.position ?? Duration.zero;
                        this._sink = StronzflixPlayerSinks.local;
                    })
                );

            throw Exception("Unknown sink");
        }

        return ControlWidget(
            hidden: this._hideControls,
            onEnter: (_) => this._cancelHideTimer(),
            onExit: (_) => this._restartHideTimer(),
            child: build()
        );
        
    }

    Widget _buildChatButton(BuildContext context) {
        return ControlWidget(
            hidden: this._hideControls,
            onEnter: (_) => this._cancelHideTimer(),
            onExit: (_) => this._restartHideTimer(),
            child: IconButton(
                icon: const Icon(Icons.chat),
                onPressed: () => super.setState(() =>
                    this._chatOpened = !this._chatOpened
                )
            )
        );
    }

    Widget _buildTitleBar(BuildContext context) {
        return Padding(
            padding: const EdgeInsets.all(10.0),
            child: Row(
                children: [
                    this._buildBackButton(context),
                    this._buildTitle(context),
                    const Spacer(),
                    this._buildCastButton(context),
                    if (PeerManager.connected)
                        this._buildChatButton(context)
                ]
            )
        );
    }

    Widget _buildExpandButton(BuildContext context) {
        return ControlWidget(
            hidden: this._hideControls,
            onEnter: (_) => this._cancelHideTimer(),
            onExit: (_) => this._restartHideTimer(),
            child: IconButton(
                onPressed: this._onExpandCollapse,
                icon: Icon(this._fullscreen ? Icons.fullscreen_exit : Icons.fullscreen)
            )
        );
    }

    Widget _buildPlayPauseButton(BuildContext context) {
        return ControlWidget(
            hidden: this._hideControls,
            onEnter: (_) => this._cancelHideTimer(),
            onExit: (_) => this._restartHideTimer(),
            child: IconButton(
                onPressed: this._onPlayPause,
                icon: AnimatedPlayPause(
                    playing: this._controller?.value.isPlaying ?? false,
                )
            )
        );
    }

    Widget _buildPosition(BuildContext context) {
        Duration position = this._controller?.position ?? Duration.zero;
        Duration duration = this._controller?.duration ?? Duration.zero;

        return ControlWidget(
            hidden: this._hideControls,
            child: Text(
                '${formatDuration(position)} / ${formatDuration(duration)}',
                style: const TextStyle(
                    fontSize: 14.0
                )
            )
        );
    }

    Widget _buildProgressBar(BuildContext context) {
        if(this._controller == null)
            return const SizedBox();

        return ControlWidget(
            hidden: this._hideControls,
            onEnter: (_) => this._cancelHideTimer(),
            onExit: (_) => this._restartHideTimer(),
            child: StronzflixPlayerProgressBar(
                controller: this._controller!,
                onDragStart: () => this._cancelHideTimer(),
                onDragUpdate: () => this._cancelHideTimer(),
                onDragEnd: () => this._restartHideTimer(),
                onSeek: (position) => this.onSeek(position),
            )
        );
    }

    Widget _buildBottomBar(BuildContext context) {
        return Padding(
            padding: const EdgeInsets.only(left: 20.0, right: 20.0, bottom: 10.0),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                verticalDirection: VerticalDirection.up,
                children: [
                    Row(
                        children: [
                            this._buildPlayPauseButton(context),
                            // const SizedBox(width: 12),
                            // this._buildMuteButton(context),
                            const SizedBox(width: 12),
                            this._buildPosition(context),
                            const Spacer(),
                            if (this._sink == StronzflixPlayerSinks.local && SPlatform.isDesktop)
                                this._buildExpandButton(context)
                        ]
                    ),
                    SizedBox(
                        height: 24,
                        child: this._buildProgressBar(context),
                    )
                ]
            )
        );
    }

    Widget _buildBuffering(BuildContext context) {
        return const ColoredBox(
            color: Colors.black54,
            child: Center(
                child: CircularProgressIndicator(),
            )
        );
    }

    Widget _buildHitArea(BuildContext context) {
        return ControlWidget(
            hidden: this._hideControls,
            ignorePointer: false,
            child: ColoredBox(
                color: Colors.black26,
                child: Container()
            ),
            onHover: (_) => this._restartHideTimer(),
            onTap: () {
                if(SPlatform.isDesktop)
                    this._onPlayPause();
            }
        );
    }

    Widget _buildChatDrawer(BuildContext context) {
        return ChatDrawer(
            shown: this._chatOpened,
        );
    }

    Widget _buildControls(BuildContext context) {
        return FocusScope(
            node: this._focusNode,
            autofocus: true,
            canRequestFocus: true,
            onKey: (data, event) => this._handleKeyControls(event),
            child: Stack(
                children: [
                    if (this._controller?.isBuffering ?? true)
                        this._buildBuffering(context)
                    else
                        this._buildHitArea(context),
                    Align(
                        alignment: Alignment.topCenter,
                        child: this._buildTitleBar(context),
                    ),
                    Align(
                        alignment: Alignment.bottomCenter,
                        child: this._buildBottomBar(context),
                    ),
                    Align(
                        alignment: Alignment.centerRight,
                        child: this._buildChatDrawer(context),
                    )
                ]
            )
        );
    }

    @override
    Widget build(BuildContext context) {
        return Stack(
            children: [
                switch(this._sink) {
                    StronzflixPlayerSinks.local => this._buildLocalPlayer(context),
                    StronzflixPlayerSinks.cast => this._buildCastPlayer(context),
                },
                this._buildControls(context)
            ],
        );
    }

    void _updateState() => super.setState(() {});

    void _restartHideTimer() {
        this._cancelHideTimer();
        this._startHideTimer();

        super.setState(() => this._hideControls = false);
    }

    void _cancelHideTimer() {
        this._hideTimer.cancel();
    }

    void _startHideTimer() {
        if(this._permanetlyShowControls)
            return;
        const Duration hideControlsTimer = Duration(seconds: 1, milliseconds: 500);
        this._hideTimer = Timer(hideControlsTimer, () => super.setState(() => this._hideControls = true));
    }

    void _onExpandCollapse() {
        super.setState(() => this._fullscreen = !this._fullscreen);
        windowManager.setFullScreen(this._fullscreen);
    }

    void _onPlayPause({bool peer = true}) {
        if(this._controller?.value.isPlaying ?? false) {
            this._permanetlyShowControls = true;
            this._hideControls = false;
            this._cancelHideTimer();
            this._controller?.pause();

            if(peer) PeerManager.pause();
        }
        else {
            this._permanetlyShowControls = false;
            this._restartHideTimer();
            this._controller?.play();

            if(peer) PeerManager.play();
        }
    }

    void onSeek(Duration position, {bool peer = true}) {
        this._controller?.seekTo(position);

        if(peer) PeerManager.seek(position.inMilliseconds);
    }

    KeyEventResult _handleKeyControls(RawKeyEvent event) {
        if(FocusManager.instance.primaryFocus != this._focusNode)
            return KeyEventResult.ignored;

        if(event is! RawKeyDownEvent)
            return KeyEventResult.ignored;

        if(event.logicalKey == LogicalKeyboardKey.arrowUp) {
            this._restartHideTimer();
            return KeyEventResult.handled;
        }

        if(event.logicalKey == LogicalKeyboardKey.arrowDown) {
            super.setState(() => this._hideControls = true);
            return KeyEventResult.handled;
        }

        if(event.logicalKey == LogicalKeyboardKey.select || event.logicalKey == LogicalKeyboardKey.space) {
            this._onPlayPause();
            return KeyEventResult.handled;
        }

        if(event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            this._restartHideTimer();
            final position = this._controller!.position;
            final seekTo = position - const Duration(seconds: 10);
            this._controller!.seekTo(seekTo > Duration.zero ? seekTo : Duration.zero);
            return KeyEventResult.handled;
        }

        if(event.logicalKey == LogicalKeyboardKey.arrowRight) {
            this._restartHideTimer();
            final position = this._controller!.position;
            final seekTo = position + const Duration(seconds: 10);
            this._controller!.seekTo(seekTo < this._controller!.duration ? seekTo : this._controller!.duration);
            return KeyEventResult.handled;
        }
        
        if (this._sink == StronzflixPlayerSinks.local && SPlatform.isDesktop)
            if(event.logicalKey == LogicalKeyboardKey.keyF) {
                this._onExpandCollapse();
                return KeyEventResult.handled;
            }

        return KeyEventResult.ignored;
    }
}
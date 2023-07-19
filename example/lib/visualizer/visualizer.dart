import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_soloud/audio_isolate.dart';
import 'package:flutter_soloud/flutter_soloud_bindings_ffi.dart';

import 'package:flutter_soloud_example/visualizer/audio_shader.dart';
import 'package:flutter_soloud_example/visualizer/bars_widget.dart';
import 'package:flutter_soloud_example/visualizer/bmp_header.dart';
import 'package:flutter_soloud_example/visualizer/paint_texture.dart';

/// enum to tell [Visualizer] to build a texture as:
/// [both1D] frequencies data on the 1st 256px row, wave on the 2nd 256px
/// [fft2D] frequencies data 256x256 px
/// [wave2D] wave data 256x256px
/// [both2D] both frequencies & wave data interleaved 256x512px
enum TextureType {
  both1D,
  fft2D,
  wave2D,
  both2D, // no implemented yet
}

class Visualizer extends StatefulWidget {
  const Visualizer({
    required this.shader,
    this.textureType = TextureType.fft2D,
    this.minImageFreqRange = 0,
    this.maxImageFreqRange = 255,
    super.key,
  }) : assert(
            minImageFreqRange < maxImageFreqRange &&
                maxImageFreqRange <= 255 &&
                minImageFreqRange >= 0,
            'min and max frequency must be in the range [0-255]!');

  final ui.FragmentShader shader;
  final TextureType textureType;
  final int minImageFreqRange;
  final int maxImageFreqRange;

  @override
  State<Visualizer> createState() => _VisualizerState();
}

class _VisualizerState extends State<Visualizer>
    with SingleTickerProviderStateMixin {
  late Ticker ticker;
  late Stopwatch sw;
  late Bmp32Header fftImageRow;
  late Bmp32Header fftImageMatrix;
  late int fftSize;
  late int halfFftSize;
  late int fftBitmapRange;
  ffi.Pointer<ffi.Pointer<ffi.Float>> audioData = ffi.nullptr;
  late Future<ui.Image?> Function() buildImageCallback;
  late int Function(int row, int col) textureTypeCallback;

  @override
  void initState() {
    super.initState();

    /// these constants must not be touched since SoLoud
    /// gives back a size of 256 values
    fftSize = 512;
    halfFftSize = fftSize >> 1;

    fftBitmapRange = widget.maxImageFreqRange - widget.minImageFreqRange;

    audioData = calloc();
    fftImageRow = Bmp32Header.setHeader(fftBitmapRange, 2);
    fftImageMatrix = Bmp32Header.setHeader(fftBitmapRange, 256);

    switch (widget.textureType) {
      case TextureType.both1D:
        {
          buildImageCallback = buildImageFromLatestSamplesRow;
          break;
        }
      case TextureType.fft2D:
        {
          buildImageCallback = buildImageFromAllSamplesMatrix;
          textureTypeCallback = getFFTDataCallback;
          break;
        }
      case TextureType.wave2D:
        {
          buildImageCallback = buildImageFromAllSamplesMatrix;
          textureTypeCallback = getWaveDataCallback;
          break;
        }
      // TODO(me): implement this
      case TextureType.both2D:
        {
          buildImageCallback = buildImageFromAllSamplesMatrix;
          textureTypeCallback = getWaveDataCallback;
          break;
        }
    }

    ticker = createTicker(_tick);
    sw = Stopwatch();
    sw.start();
    ticker.start();
  }

  @override
  void dispose() {
    ticker.stop();
    sw.stop();
    calloc.free(audioData);
    audioData = ffi.nullptr;
    super.dispose();
  }

  void _tick(Duration elapsed) {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image?>(
      future: buildImageCallback(),
      builder: (context, dataTexture) {
        if (!dataTexture.hasData || dataTexture.data == null) {
          return const Placeholder(
            color: Colors.yellow,
            fallbackWidth: 100,
            fallbackHeight: 100,
            strokeWidth: 0.5,
            child: Text("can't get audio samples"),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                /// paint texture passed to the shader
                PaintTexture(
                  text: 'the texture sent to the shader',
                  width: constraints.maxWidth,
                  height: 120,
                  image: dataTexture.data!,
                ),

                AudioShader(
                  text: 'SHADER',
                  width: constraints.maxWidth,
                  height: constraints.maxWidth / 2,
                  image: dataTexture.data!,
                  shader: widget.shader,
                  iTime: sw.elapsedMilliseconds / 1000.0,
                ),

                Row(
                  children: [
                    /// FFT bars
                    BarsWidget(
                      text: '256 FFT data',
                      audioData: audioData.value,
                      n: halfFftSize,
                      useFftData: true,
                      width: constraints.maxWidth / 2 - 3,
                      height: constraints.maxWidth / 4,
                    ),
                    const SizedBox(width: 6),

                    /// wave data bars
                    BarsWidget(
                      text: '256 wave data',
                      audioData: audioData.value,
                      n: halfFftSize,
                      width: constraints.maxWidth / 2 - 3,
                      height: constraints.maxWidth / 4,
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// build an image to be passed to the shader.
  /// The image is a matrix of 256x2 RGBA pixels representing:
  /// in the 1st row the frequencies data
  /// in the 2nd row the wave data
  Future<ui.Image?> buildImageFromLatestSamplesRow() async {
    if (audioData == ffi.nullptr) return null;
    final completer = Completer<ui.Image>();

    /// audioData here will be available to all the children of [Visualizer]
    final ret = await AudioIsolate().getAudioTexture2D(audioData);
    if (ret != PlayerErrors.noError || !mounted) return null;

    final bytes = Uint8List(fftBitmapRange * 2 * 4);
    // Fill the texture bitmap
    var col = 0;
    for (var i = widget.minImageFreqRange;
        i < widget.maxImageFreqRange;
        ++i, ++col) {
      // fill 1st bitmap row with magnitude
      bytes[col * 4 + 0] = getFFTDataCallback(0, i);
      bytes[col * 4 + 1] = 0;
      bytes[col * 4 + 2] = 0;
      bytes[col * 4 + 3] = 255;
      // fill 2nd bitmap row with amplitude
      bytes[(fftBitmapRange + col) * 4 + 0] = getWaveDataCallback(0, i);
      bytes[(fftBitmapRange + col) * 4 + 1] = 0;
      bytes[(fftBitmapRange + col) * 4 + 2] = 0;
      bytes[(fftBitmapRange + col) * 4 + 3] = 255;
    }

    final img = fftImageRow.storeBitmap(bytes);
    ui.decodeImageFromList(img, completer.complete);

    return completer.future;
  }

  /// build an image to be passed to the shader.
  /// The image is a matrix of 256x256 RGBA pixels representing
  /// rows of wave data or frequencies data.
  /// Passing [getWaveDataCallback] as parameter, it will return wave data
  /// Passing [getFFTDataCallback] as parameter, it will return FFT data
  Future<ui.Image?> buildImageFromAllSamplesMatrix() async {
    final completer = Completer<ui.Image>();

    /// audioData here will be available to all the children of [Visualizer]
    final ret = await AudioIsolate().getAudioTexture2D(audioData);
    /// IMPORTANT: if [mounted] is not checked here, could happens that
    /// dispose() is called before this is called but it is called!
    /// Since in dispose the [audioData] is freed, there will be a crash!
    /// I do not understand why this happens because the FutureBuilder
    /// seems has not finished before dispose()!?
    /// My psychoanalyst told me to forget it and my mom to study more
    if (ret != PlayerErrors.noError || !mounted) {
      return null;
    }
    final bytes = Uint8List(fftBitmapRange * 256 * 4);

    // Fill the texture bitmap with wave data
    for (var y = 0; y < 256; ++y) {
      var col = 0;
      for (var x = widget.minImageFreqRange;
          x < widget.maxImageFreqRange;
          ++x, ++col) {
        bytes[y * fftBitmapRange * 4 + col * 4 + 0] = textureTypeCallback(y, x);
        bytes[y * fftBitmapRange * 4 + col * 4 + 1] = 0;
        bytes[y * fftBitmapRange * 4 + col * 4 + 2] = 0;
        bytes[y * fftBitmapRange * 4 + col * 4 + 3] = 255;
      }
    }

    final img = fftImageMatrix.storeBitmap(bytes);
    ui.decodeImageFromList(img, completer.complete);

    return completer.future;
  }

  int getFFTDataCallback(int row, int col) {
    return (audioData.value[row * fftSize + col] * 255.0).toInt();
  }

  int getWaveDataCallback(int row, int col) {
    return (((audioData.value[row * fftSize + halfFftSize + col] + 1.0) / 2.0) *
            128)
        .toInt();
  }
}
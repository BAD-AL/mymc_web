import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:vector_math/vector_math.dart';
import 'package:dart_mymc/dart_mymc.dart';

class Ps2IconRenderer {
  // Singleton resources shared by all icons
  static web.HTMLCanvasElement? _offscreenCanvas;
  static web.WebGL2RenderingContext? _gl;
  static web.WebGLProgram? _program;
  static final Map<String, int> _attribs = {};
  static final Map<String, web.WebGLUniformLocation> _uniforms = {};

  // Cache for live animation performance
  static Ps2IconData? _lastData;
  static web.WebGLBuffer? _cPos, _cNorm, _cUv, _cCol;
  static web.WebGLTexture? _cTex;

  static void _ensureInitialized() {
    if (_gl != null) return;

    _offscreenCanvas = web.document.createElement('canvas') as web.HTMLCanvasElement;
    _offscreenCanvas!.width = 128;
    _offscreenCanvas!.height = 128;

    _gl = _offscreenCanvas!.getContext('webgl2', {
      'preserveDrawingBuffer': true,
      'alpha': true,
    }.jsify() as web.WebGLContextAttributes) as web.WebGL2RenderingContext;

    _program = _createProgram(_gl!, _vShaderSource, _fShaderSource);
    _gl!.useProgram(_program);

    _attribs['a_pos'] = _gl!.getAttribLocation(_program!, 'a_pos');
    _attribs['a_normal'] = _gl!.getAttribLocation(_program!, 'a_normal');
    _attribs['a_uv'] = _gl!.getAttribLocation(_program!, 'a_uv');
    _attribs['a_color'] = _gl!.getAttribLocation(_program!, 'a_color');

    _uniforms['u_mvp'] = _gl!.getUniformLocation(_program!, 'u_mvp')!;
    _uniforms['u_texture'] = _gl!.getUniformLocation(_program!, 'u_texture')!;
    _uniforms['u_ambient'] = _gl!.getUniformLocation(_program!, 'u_ambient')!;
    _uniforms['u_lightDir1'] = _gl!.getUniformLocation(_program!, 'u_lightDir1')!;
    _uniforms['u_lightColor1'] = _gl!.getUniformLocation(_program!, 'u_lightColor1')!;
    _uniforms['u_lightDir2'] = _gl!.getUniformLocation(_program!, 'u_lightDir2')!;
    _uniforms['u_lightColor2'] = _gl!.getUniformLocation(_program!, 'u_lightColor2')!;
    _uniforms['u_lightDir3'] = _gl!.getUniformLocation(_program!, 'u_lightDir3')!;
    _uniforms['u_lightColor3'] = _gl!.getUniformLocation(_program!, 'u_lightColor3')!;
  }

  static JSObject _safeToJS(TypedData list) {
    if (list is Float32List) return list.toJS;
    if (list is Uint8List) return list.toJS;
    return (list as dynamic).toJS as JSObject;
  }

  static void renderToCanvas(web.HTMLCanvasElement targetCanvas, Ps2IconData data, {double rotationAngle = 0.0}) {
    _ensureInitialized();
    final gl = _gl!;

    // 1. Calculate Bounding Box
    double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity, maxZ = double.negativeInfinity;
    
    final firstFrame = data.positions[0];
    for (int i = 0; i < data.vertexCount; i++) {
      final x = firstFrame[i * 3];
      final y = firstFrame[i * 3 + 1];
      final z = firstFrame[i * 3 + 2];
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
      if (z < minZ) minZ = z; if (z > maxZ) maxZ = z;
    }
    
    final centerX = (minX + maxX) / 2.0;
    final centerY = (minY + maxY) / 2.0;
    final centerZ = (minZ + maxZ) / 2.0;
    final maxDim = [maxX - minX, maxY - minY, maxZ - minZ].reduce(math.max);
    final scale = maxDim > 0 ? (1.3 / maxDim) : 1.0;

    // 2. Manage Buffers & Texture (Cache check)
    if (_lastData != data) {
      if (_cPos != null) gl.deleteBuffer(_cPos!);
      if (_cNorm != null) gl.deleteBuffer(_cNorm!);
      if (_cUv != null) gl.deleteBuffer(_cUv!);
      if (_cCol != null) gl.deleteBuffer(_cCol!);
      if (_cTex != null) gl.deleteTexture(_cTex!);

      _cPos = _createBuffer(gl, firstFrame);
      _cNorm = _createBuffer(gl, data.normals);
      _cUv = _createBuffer(gl, data.uvs);
      _cCol = _createBuffer(gl, data.vertexColors);
      
      if (data.texture != null) {
        _cTex = gl.createTexture();
        gl.bindTexture(web.WebGLRenderingContext.TEXTURE_2D, _cTex);
        gl.texImage2D(
          web.WebGLRenderingContext.TEXTURE_2D, 0, web.WebGLRenderingContext.RGB,
          128.toJS as JSAny, 128.toJS as JSAny, 0.toJS as JSAny, web.WebGLRenderingContext.RGB,
          web.WebGLRenderingContext.UNSIGNED_BYTE, _safeToJS(data.texture!));
        gl.generateMipmap(web.WebGLRenderingContext.TEXTURE_2D);
      } else {
        _cTex = null;
      }
      _lastData = data;
    }

    // 3. Render
    gl.viewport(0, 0, 128, 128);
    final bg = data.bgColors; 
    gl.clearColor(bg[0]/255, bg[1]/255, bg[2]/255, 1.0);
    gl.clear(web.WebGLRenderingContext.COLOR_BUFFER_BIT | web.WebGLRenderingContext.DEPTH_BUFFER_BIT);

    gl.useProgram(_program);
    gl.enable(web.WebGLRenderingContext.DEPTH_TEST);
    
    // Enable culling to ensure correct winding (PS2 icons usually CCW)
    gl.enable(web.WebGLRenderingContext.CULL_FACE);
    gl.cullFace(web.WebGLRenderingContext.BACK);

    final projection = makePerspectiveMatrix(radians(45), 1.0, 0.1, 100.0);
    final view = makeViewMatrix(Vector3(0, 0, 2.5), Vector3(0, 0, 0), Vector3(0, 1, 0));
    
    // Build Model Matrix with Centering, Scaling, and 180-degree flip to show the front
    final model = Matrix4.identity()
      ..rotateY(radians(rotationAngle + 200)) // 20 + 180 to show the front
      ..rotateX(radians(-10))
      ..scale(-scale, -scale, scale) 
      ..translate(-centerX, -centerY, -centerZ);
    
    final mvp = projection * view * model;
    
    gl.uniformMatrix4fv(_uniforms['u_mvp']!, false, _safeToJS(mvp.storage));
    gl.uniform3f(_uniforms['u_ambient']!, data.ambient[0].toDouble(), data.ambient[1].toDouble(), data.ambient[2].toDouble());
    gl.uniform3f(_uniforms['u_lightDir1']!, data.lightDir1[0].toDouble(), data.lightDir1[1].toDouble(), data.lightDir1[2].toDouble());
    gl.uniform3f(_uniforms['u_lightColor1']!, data.lightColor1[0].toDouble(), data.lightColor1[1].toDouble(), data.lightColor1[2].toDouble());
    gl.uniform3f(_uniforms['u_lightDir2']!, data.lightDir2[0].toDouble(), data.lightDir2[1].toDouble(), data.lightDir2[2].toDouble());
    gl.uniform3f(_uniforms['u_lightColor2']!, data.lightColor2[0].toDouble(), data.lightColor2[1].toDouble(), data.lightColor2[2].toDouble());
    gl.uniform3f(_uniforms['u_lightDir3']!, data.lightDir3[0].toDouble(), data.lightDir3[1].toDouble(), data.lightDir3[2].toDouble());
    gl.uniform3f(_uniforms['u_lightColor3']!, data.lightColor3[0].toDouble(), data.lightColor3[1].toDouble(), data.lightColor3[2].toDouble());

    _bindAttrib(gl, _attribs['a_pos']!, _cPos!, 3);
    _bindAttrib(gl, _attribs['a_normal']!, _cNorm!, 3);
    _bindAttrib(gl, _attribs['a_uv']!, _cUv!, 2);
    _bindAttrib(gl, _attribs['a_color']!, _cCol!, 4, type: web.WebGLRenderingContext.UNSIGNED_BYTE, normalize: true);

    if (_cTex != null) {
      gl.activeTexture(web.WebGLRenderingContext.TEXTURE0);
      gl.bindTexture(web.WebGLRenderingContext.TEXTURE_2D, _cTex);
      gl.uniform1i(_uniforms['u_texture']!, 0);
    }

    gl.drawArrays(web.WebGLRenderingContext.TRIANGLES, 0, data.vertexCount);

    final ctx2d = targetCanvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx2d.clearRect(0, 0, targetCanvas.width, targetCanvas.height);
    ctx2d.drawImage(_offscreenCanvas! as web.CanvasImageSource, 0, 0, targetCanvas.width, targetCanvas.height);
  }

  static web.WebGLBuffer _createBuffer(web.WebGL2RenderingContext gl, TypedData data) {
    final buffer = gl.createBuffer()!;
    gl.bindBuffer(web.WebGLRenderingContext.ARRAY_BUFFER, buffer);
    gl.bufferData(web.WebGLRenderingContext.ARRAY_BUFFER, _safeToJS(data), web.WebGLRenderingContext.STATIC_DRAW);
    return buffer;
  }

  static void _bindAttrib(web.WebGL2RenderingContext gl, int loc, web.WebGLBuffer buffer, int size, {int type = web.WebGLRenderingContext.FLOAT, bool normalize = false}) {
    if (loc < 0) return;
    gl.bindBuffer(web.WebGLRenderingContext.ARRAY_BUFFER, buffer);
    gl.vertexAttribPointer(loc, size, type, normalize, 0, 0);
    gl.enableVertexAttribArray(loc);
  }

  static web.WebGLProgram _createProgram(web.WebGL2RenderingContext gl, String vSrc, String fSrc) {
    final vs = _createShader(gl, web.WebGLRenderingContext.VERTEX_SHADER, vSrc);
    final fs = _createShader(gl, web.WebGLRenderingContext.FRAGMENT_SHADER, fSrc);
    final prog = gl.createProgram()!;
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    return prog;
  }

  static web.WebGLShader _createShader(web.WebGL2RenderingContext gl, int type, String src) {
    final s = gl.createShader(type)!;
    gl.shaderSource(s, src);
    gl.compileShader(s);
    return s;
  }

  static const _vShaderSource = '''#version 300 es
    layout(location = 0) in vec3 a_pos;
    layout(location = 1) in vec3 a_normal;
    layout(location = 2) in vec2 a_uv;
    layout(location = 3) in vec4 a_color;
    uniform mat4 u_mvp;
    out vec2 v_uv;
    out vec4 v_color;
    out vec3 v_normal;
    void main() {
      gl_Position = u_mvp * vec4(a_pos, 1.0);
      v_uv = a_uv;
      v_color = a_color;
      v_normal = a_normal;
    }
  ''';

  static const _fShaderSource = '''#version 300 es
    precision mediump float;
    in vec2 v_uv;
    in vec4 v_color;
    in vec3 v_normal;
    uniform sampler2D u_texture;
    uniform vec3 u_ambient;
    uniform vec3 u_lightDir1;
    uniform vec3 u_lightColor1;
    uniform vec3 u_lightDir2;
    uniform vec3 u_lightColor2;
    uniform vec3 u_lightDir3;
    uniform vec3 u_lightColor3;
    out vec4 outColor;
    void main() {
      vec4 texColor = texture(u_texture, v_uv);
      if (texColor.a < 0.1) discard;
      vec4 baseColor = texColor * v_color;
      vec3 normal = normalize(v_normal);
      vec3 light = u_ambient;
      light += u_lightColor1 * max(dot(normal, normalize(u_lightDir1)), 0.0);
      light += u_lightColor2 * max(dot(normal, normalize(u_lightDir2)), 0.0);
      light += u_lightColor3 * max(dot(normal, normalize(u_lightDir3)), 0.0);
      outColor = vec4(baseColor.rgb * light, baseColor.a);
    }
  ''';
}

# DirectGPU 1.0.25 Lua export inventory

Static jar verification; these are signatures, not sandbox-verified Lua calls. 149 annotated public methods. Java `IArguments` means a vararg parser; see the review for the relevant argument forms. Parameter names come from the class LocalVariableTable. JVM types are preserved to avoid guessed Lua APIs.

| Method | Java argument types | Parameter names |
|---|---|---|
| `createDisplay` | `dan200.computercraft.api.lua.IArguments` | args |
| `createDisplayAt` | `dan200.computercraft.api.lua.IArguments` | args |
| `createDisplayWithResolution` | `int, int, int, java.lang.String, int, int, double` | x, y, z, facing, width, height, resolutionMultiplier |
| `removeDisplay` | `int` | displayId |
| `listDisplays` | `` |  |
| `getDisplayInfo` | `int` | displayId |
| `clearAllDisplays` | `` |  |
| `stopGIF` | `int` | displayId |
| `getResourceStats` | `` |  |
| `setPixel` | `int, int, int, int, int, int` | displayId, x, y, r, g, b |
| `getPixel` | `int, int, int` | displayId, x, y |
| `clear` | `int, int, int, int` | displayId, r, g, b |
| `fillRect` | `int, int, int, int, int, int, int, int` | displayId, x, y, w, h, r, g, b |
| `clipRect` | `int, int, int, int, int` | displayId, x, y, w, h |
| `clearClip` | `int` | displayId |
| `drawLine` | `int, int, int, int, int, int, int, int` | displayId, x1, y1, x2, y2, r, g, b |
| `drawPolylines` | `int, java.lang.Object, int, int, int` | displayId, pointsObj, r, g, b |
| `drawPolygon` | `int, java.lang.Object, int, int, int` | displayId, pointsObj, r, g, b |
| `drawCircle` | `int, int, int, int, int, int, int, boolean` | displayId, cx, cy, radius, r, g, b, filled |
| `drawEllipse` | `int, int, int, int, int, int, int, int, boolean` | displayId, cx, cy, rx, ry, r, g, b, filled |
| `fillEllipse` | `int, int, int, int, int, int, int, int` | displayId, cx, cy, rx, ry, r, g, b |
| `updateDisplay` | `int` | displayId |
| `drawText` | `int, java.lang.String, int, int, int, int, int, java.lang.String, int, java.lang.String` | displayId, text, x, y, r, g, b, fontName, fontSize, style |
| `measureText` | `java.lang.String, java.lang.String, int, java.lang.String` | text, fontName, fontSize, style |
| `drawTextWithBg` | `int, java.lang.String, int, int, int, int, int, int, int, int, int, java.lang.String, int, java.lang.String` | displayId, text, x, y, fgR, fgG, fgB, bgR, bgG, bgB, padding, fontName, fontSize, style |
| `drawTextWrapped` | `int, java.lang.String, int, int, int, int, int, int, int, java.lang.String, int, java.lang.String` | displayId, text, x, y, maxWidth, r, g, b, lineSpacing, fontName, fontSize, style |
| `getAvailableFonts` | `` |  |
| `clearFontCache` | `` |  |
| `loadJPEGRegion` | `int, java.lang.String, int, int, int, int` | displayId, jpegBinaryData, x, y, w, h |
| `loadJPEGRegionBytes` | `int, java.lang.String, int, int, int, int` | displayId, base64JpegData, x, y, w, h |
| `loadJPEGFullscreen` | `int, java.lang.String` | displayId, base64JpegData |
| `getRecommendedJPEGSettings` | `int, int` | targetWidth, targetHeight |
| `clearJPEGCache` | `` |  |
| `preloadJPEGSequence` | `int, java.util.Map<?, ?>` | displayId, jpegSequence, jpegSequence |
| `getJPEGNetworkStats` | `` |  |
| `decodeJPEG` | `java.lang.String` | base64JpegData |
| `decodeAndScaleJPEG` | `java.lang.String, int, int` | base64JpegData, targetWidth, targetHeight |
| `getJPEGDimensions` | `java.lang.String` | base64JpegData |
| `loadPNGRegion` | `int, java.lang.String, int, int, int, int` | displayId, pngBinaryData, x, y, w, h |
| `loadPNGRegionBytes` | `int, java.lang.String, int, int, int, int` | displayId, base64PngData, x, y, w, h |
| `loadPNGFullscreen` | `int, java.lang.String` | displayId, base64PngData |
| `decodePNG` | `java.lang.String` | base64PngData |
| `decodeAndScalePNG` | `java.lang.String, int, int` | base64PngData, targetWidth, targetHeight |
| `getPNGDimensions` | `java.lang.String` | base64PngData |
| `loadImageRegionBytes` | `int, java.lang.String, int, int, int, int` | displayId, base64ImageData, x, y, w, h |
| `loadBlurredImage` | `dan200.computercraft.api.lua.IArguments` | args |
| `loadBlurredImageBytes` | `dan200.computercraft.api.lua.IArguments` | args |
| `loadCoverImageRegion` | `dan200.computercraft.api.lua.IArguments` | args |
| `loadCoverImageRegionBytes` | `dan200.computercraft.api.lua.IArguments` | args |
| `getBlurRadiusForPercent` | `int, double` | displayId, percent |
| `restoreBackdrop` | `int, int, int, int, int` | displayId, x, y, w, h |
| `clearBackdrop` | `int` | displayId |
| `loadImageFullscreen` | `int, java.lang.String` | displayId, base64ImageData |
| `decodeImage` | `java.lang.String` | base64ImageData |
| `decodeAndScaleImage` | `java.lang.String, int, int` | base64ImageData, targetWidth, targetHeight |
| `getImageDimensions` | `java.lang.String` | base64ImageData |
| `detectImageFormat` | `java.lang.String` | base64ImageData |
| `compressWithDict` | `java.lang.String` | base64Data |
| `decompressFromDict` | `java.util.Map<?, ?>` | hashMap, hashMap |
| `hasChunk` | `long` | hash |
| `getChunk` | `long` | hash |
| `getDictionaryStats` | `` |  |
| `clearDictionary` | `` |  |
| `pollEvent` | `int` | displayId |
| `enableMouseEvents` | `int, boolean, java.util.Optional<java.lang.Boolean>` | displayId, enabled, includeHover, includeHover |
| `hasEvents` | `int` | displayId |
| `clearEvents` | `int` | displayId |
| `setupCamera` | `int, double, double, double` | displayId, fov, near, far |
| `setCameraPosition` | `int, double, double, double` | displayId, x, y, z |
| `setCameraRotation` | `int, double, double, double` | displayId, pitch, yaw, roll |
| `lookAt` | `int, double, double, double` | displayId, targetX, targetY, targetZ |
| `getCameraInfo` | `int` | displayId |
| `clearZBuffer` | `int` | displayId |
| `drawCube` | `int, double, double, double, double, double, double, double, int, int, int` | displayId, x, y, z, size, rotX, rotY, rotZ, r, g, b |
| `drawSphere` | `int, double, double, double, double, int, int, int, int, java.lang.Object` | displayId, x, y, z, radius, segments, r, g, b, textureNameObj |
| `drawPyramid` | `int, double, double, double, double, double, double, double, int, int, int` | displayId, x, y, z, size, rotX, rotY, rotZ, r, g, b |
| `clear3D` | `int` | displayId |
| `load3DModel` | `java.lang.String` | objData |
| `load3DModelFromBytes` | `java.lang.String` | base64ObjData |
| `draw3DModel` | `dan200.computercraft.api.lua.IArguments` | args |
| `unload3DModel` | `int` | modelId |
| `get3DModelInfo` | `int` | modelId |
| `get3DStats` | `int` | displayId |
| `clearAll3DModels` | `` |  |
| `getWorldInfo` | `` |  |
| `getWeather` | `` |  |
| `getTimeInfo` | `` |  |
| `getMoonInfo` | `` |  |
| `getDimension` | `` |  |
| `getBiomeAt` | `int, int, int` | x, y, z |
| `setCalibrationMode` | `boolean, double, double` | enabled, divisor, subtract |
| `getCalibrationValues` | `` |  |
| `autoDetectMonitor` | `dan200.computercraft.api.lua.IArguments` | args |
| `autoDetectMonitorInfo` | `dan200.computercraft.api.lua.IArguments` | args |
| `autoDetectMonitors` | `dan200.computercraft.api.lua.IArguments` | args |
| `autoDetectAndCreateDisplays` | `dan200.computercraft.api.lua.IArguments` | args |
| `mirrorDisplay` | `int, java.util.Map<?, ?>` | sourceDisplayId, targetDisplayIds, targetDisplayIds |
| `autoDetectAndCreateDisplay` | `dan200.computercraft.api.lua.IArguments` | args |
| `autoDetectAndCreateDisplayWithResolution` | `dan200.computercraft.api.lua.IArguments` | args |
| `loadTexture` | `int, int, java.lang.String` | width, height, base64PixelData |
| `loadTextureFromImage` | `java.util.Map<?, ?>` | imageData |
| `loadTextureImage` | `java.lang.String` | base64ImageData |
| `loadTextureImageBytes` | `java.lang.String` | base64ImageData |
| `loadJPGTexture` | `java.lang.String` | base64ImageData |
| `loadPNGTexture` | `java.lang.String` | base64ImageData |
| `unloadTexture` | `int` | textureId |
| `getTextureInfo` | `int` | textureId |
| `addDirectionalLight` | `int, double, double, double, int, int, int, double` | displayId, dirX, dirY, dirZ, r, g, b, intensity |
| `clearLights` | `int` | displayId |
| `draw3DModelTextured` | `dan200.computercraft.api.lua.IArguments` | args |
| `drawBezierCurve` | `int, java.lang.Object, int, int, int, java.lang.Object` | displayId, pointsObj, r, g, b, segmentsObj |
| `drawSVGPath` | `int, java.lang.String, int, int, double, int, int, int` | displayId, pathData, x, y, scale, r, g, b |
| `drawRoundedRect` | `int, int, int, int, int, int, int, int, int, boolean` | displayId, x, y, w, h, radius, r, g, b, filled |
| `drawStar` | `int, int, int, int, int, int, int, int, int, boolean` | displayId, cx, cy, points, outerRadius, innerRadius, r, g, b, filled |
| `setCameraTarget` | `int, double, double, double` | displayId, x, y, z |
| `addAmbientLight` | `int, int, int, int, double` | displayId, r, g, b, intensity |
| `setBackfaceCulling` | `int, boolean` | displayId, enabled |
| `setPhongShading` | `int, boolean` | displayId, enabled |
| `createMetaballSystem` | `int` | displayId |
| `addMetaball` | `int, double, double, double, double` | systemId, x, y, radius, strength |
| `setMetaballVelocity` | `int, int, double, double` | systemId, ballId, vx, vy |
| `setMetaballColor` | `int, int, int, int, int` | systemId, ballId, r, g, b |
| `setMetaballPhysics` | `int, boolean, double, double` | systemId, enabled, gravity, drag |
| `updateMetaballs` | `int, double` | systemId, deltaTime |
| `renderMetaballs` | `int, double, int` | systemId, threshold, renderMode |
| `clearMetaballs` | `int` | systemId |
| `removeMetaballSystem` | `int` | systemId |
| `getMetaballCount` | `int` | systemId |
| `getMetaballInfo` | `int, int` | systemId, ballId |
| `loadGIFRegion` | `int, java.lang.String, int, int, int, int` | displayId, gifBinaryData, x, y, w, h |
| `loadGIFRegionBytes` | `int, java.lang.String, int, int, int, int` | displayId, base64GifData, x, y, w, h |
| `loadGIFFullscreen` | `int, java.lang.String` | displayId, gifDataString |
| `loadGIFFrame` | `int, java.lang.String, int, int, int, int, int` | displayId, gifDataString, frameIndex, x, y, w, h |
| `decodeGIF` | `java.lang.String` | base64GifData |
| `decodeAndScaleGIF` | `java.lang.String, int, int` | base64GifData, targetWidth, targetHeight |
| `getGIFDimensions` | `java.lang.String` | base64GifData |
| `getGIFFrameInfo` | `java.lang.String` | base64GifData |
| `setRotation` | `int, double, double` | displayId, pitch, yaw |
| `getRotation` | `int` | displayId |
| `moveDisplay` | `int, double, double, double, dan200.computercraft.api.lua.IArguments` | displayId, targetX, targetY, targetZ, args |
| `setDisplayPosition` | `int, double, double, double` | displayId, x, y, z |
| `stopDisplayMovement` | `int` | displayId |
| `getDisplayPosition` | `int` | displayId |
| `enableDeltaMode` | `int` | displayId |
| `setOpacity` | `int, double` | displayId, opacity |
| `setBackgroundOpacity` | `int, double` | displayId, opacity |
| `getDisplayFrameJpeg` | `int, java.util.Optional<java.lang.Integer>` | displayId, quality, quality |
| `termRedirect` | `int` | displayId |
| `termRender` | `dan200.computercraft.api.lua.IArguments` | args |

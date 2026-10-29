package com.pointverse.app;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.ImageFormat;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.*;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.Looper;
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;
import java.nio.ByteBuffer;
import java.util.*;
import java.util.function.Consumer;

/** Camera state and callbacks are serialized on the main looper. Audio owns a separate recorder. */
final class CaptureCamera {
    static final long SAMPLE_INTERVAL_MS = 1200;
    static final int MAX_CAPTURED_FRAMES = 12;
    static final int MAX_REVIEW_FRAMES = 5;
    enum State { OPENING, READY, FAILED, CLOSED }
    private final Activity activity;
    private final TextureView view;
    private final Consumer<String> error;
    private final Consumer<State> changed;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<byte[]> frames = new ArrayList<>();
    private CameraDevice device;
    private CameraCaptureSession session;
    private ImageReader reader;
    private Surface preview;
    private Size previewSize, jpegSize;
    private int orientation = 90, focusMode = CaptureRequest.CONTROL_AF_MODE_OFF;
    private boolean front, opening, closed, configured, collecting, inFlight, draining;
    private long recordingId, flightId, lastSampleAt;
    private int openRetries;
    private State state = State.OPENING;
    private Consumer<List<byte[]>> finishCallback;

    CaptureCamera(Activity activity, TextureView view, Consumer<String> error, Consumer<State> changed) {
        this.activity = activity;
        this.view = view;
        this.error = error;
        this.changed = changed;
        view.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            public void onSurfaceTextureAvailable(SurfaceTexture texture, int width, int height) { open(); }
            public void onSurfaceTextureSizeChanged(SurfaceTexture texture, int width, int height) { transform(); }
            public boolean onSurfaceTextureDestroyed(SurfaceTexture texture) { close(); return true; }
            public void onSurfaceTextureUpdated(SurfaceTexture texture) {
                if (configured && !closed && state != State.READY) {
                    setState(State.READY);
                    if (collecting) sampleNow();
                }
            }
        });
        if (view.isAvailable()) open();
    }

    boolean isReady() { return state == State.READY; }
    private void setState(State value) { if (state != value) { state = value; changed.accept(value); } }

    @SuppressWarnings("MissingPermission")
    private void open() {
        if (closed || opening || device != null) return;
        if (activity.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            fail("请先允许相机权限，录音仍可单独使用"); return;
        }
        opening = true;
        try {
            CameraManager manager = (CameraManager) activity.getSystemService(Context.CAMERA_SERVICE);
            String selected = null;
            CameraCharacteristics characteristics = null;
            // Prefer a rear camera, but support devices that only expose a front camera.
            for (String id : manager.getCameraIdList()) {
                CameraCharacteristics candidate = manager.getCameraCharacteristics(id);
                StreamConfigurationMap map = candidate.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
                if (map == null || map.getOutputSizes(SurfaceTexture.class) == null
                        || map.getOutputSizes(ImageFormat.JPEG) == null) continue;
                if (selected == null || Objects.equals(candidate.get(CameraCharacteristics.LENS_FACING),
                        CameraCharacteristics.LENS_FACING_BACK)) {
                    selected = id; characteristics = candidate;
                    if (Objects.equals(candidate.get(CameraCharacteristics.LENS_FACING),
                            CameraCharacteristics.LENS_FACING_BACK)) break;
                }
            }
            if (selected == null) throw new IllegalStateException("No supported camera");
            StreamConfigurationMap map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
            jpegSize = chooseJpeg(map.getOutputSizes(ImageFormat.JPEG));
            previewSize = choosePreview(map.getOutputSizes(SurfaceTexture.class), jpegSize);
            Integer sensor = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
            orientation = sensor == null ? 90 : sensor;
            front = Objects.equals(characteristics.get(CameraCharacteristics.LENS_FACING),
                    CameraCharacteristics.LENS_FACING_FRONT);
            int[] modes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES);
            if (modes != null) for (int value : modes) {
                if (value == CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) { focusMode = value; break; }
                if (value == CaptureRequest.CONTROL_AF_MODE_AUTO) focusMode = value;
            }
            manager.openCamera(selected, new CameraDevice.StateCallback() {
                public void onOpened(CameraDevice camera) {
                    opening = false;
                    if (closed) { camera.close(); return; }
                    device = camera; configure();
                }
                public void onDisconnected(CameraDevice camera) {
                    camera.close(); if (!closed) fail("相机连接已中断，可关闭后重新打开；录音仍在继续");
                }
                public void onError(CameraDevice camera, int code) {
                    camera.close();
                    if (closed) return;
                    if ((code == ERROR_CAMERA_IN_USE || code == ERROR_MAX_CAMERAS_IN_USE) && openRetries++ < 2) {
                        opening = false; main.postDelayed(() -> open(), 250); return;
                    }
                    fail(code == ERROR_CAMERA_DISABLED ? "系统已关闭相机访问，请在系统设置中开启；录音仍可继续"
                            : "相机未能打开，可能正被其他应用占用；录音仍可继续");
                }
            }, main);
        } catch (Exception e) { fail("无法打开相机，请检查权限或相机占用；录音仍可继续"); }
    }

    static Size chooseJpeg(Size[] choices) {
        if (choices == null || choices.length == 0) throw new IllegalArgumentException("No JPEG sizes");
        Size best = null, smallest = choices[0];
        for (Size value : choices) {
            if (area(value) < area(smallest)) smallest = value;
            if (value.getWidth() <= 1600 && value.getHeight() <= 1600
                    && (best == null || area(value) > area(best))) best = value;
        }
        return best == null ? smallest : best;
    }

    static Size choosePreview(Size[] choices, Size jpeg) {
        if (choices == null || choices.length == 0) throw new IllegalArgumentException("No preview sizes");
        Size best = null;
        double bestScore = Double.MAX_VALUE;
        for (Size value : choices) {
            double ratio = (double) value.getWidth() / value.getHeight();
            double target = (double) jpeg.getWidth() / jpeg.getHeight();
            double score = Math.abs(ratio - target) * 10000
                    + Math.abs(Math.max(value.getWidth(), value.getHeight()) - 1280);
            if (Math.max(value.getWidth(), value.getHeight()) > 1920
                    || Math.min(value.getWidth(), value.getHeight()) > 1080) score += 100000;
            if (score < bestScore) { best = value; bestScore = score; }
        }
        return best;
    }
    private static long area(Size value) { return (long) value.getWidth() * value.getHeight(); }

    private void configure() {
        if (closed) return;
        try {
            SurfaceTexture texture = view.getSurfaceTexture();
            if (texture == null) { fail("相机预览尚未就绪，请重新打开"); return; }
            texture.setDefaultBufferSize(previewSize.getWidth(), previewSize.getHeight());
            preview = new Surface(texture);
            reader = ImageReader.newInstance(jpegSize.getWidth(), jpegSize.getHeight(), ImageFormat.JPEG, 2);
            reader.setOnImageAvailableListener(source -> receiveImage(source), main);
            transform();
            device.createCaptureSession(Arrays.asList(preview, reader.getSurface()),
                    new CameraCaptureSession.StateCallback() {
                public void onConfigured(CameraCaptureSession configuredSession) {
                    if (closed) { configuredSession.close(); return; }
                    session = configuredSession;
                    try {
                        CaptureRequest.Builder request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);
                        request.addTarget(preview);
                        request.set(CaptureRequest.CONTROL_AF_MODE, focusMode);
                        session.setRepeatingRequest(request.build(), null, main);
                        configured = true;
                    } catch (Exception e) { fail("相机预览无法启动，可关闭后重试；录音仍可继续"); }
                }
                public void onConfigureFailed(CameraCaptureSession failedSession) {
                    failedSession.close(); if (!closed) fail("设备无法建立相机预览，可关闭后重试；录音仍可继续");
                }
            }, main);
        } catch (Exception e) { fail("相机预览无法启动，可关闭后重试；录音仍可继续"); }
    }

    private int rotationDegrees() {
        return new int[]{0, 90, 180, 270}[activity.getWindowManager().getDefaultDisplay().getRotation()];
    }
    private void transform() {
        if (previewSize == null || view.getWidth() == 0 || view.getHeight() == 0) return;
        view.setTransform(previewTransform(view.getWidth(), view.getHeight(), previewSize,
                orientation, front, rotationDegrees()));
    }
    // TextureView already applies the sensor rotation. Only compensate display rotation and scale.
    // Scaling follows Android's camera2 resizable-preview codelab:
    // https://developer.android.com/codelabs/android-camera2-preview
    static Matrix previewTransform(int width, int height, Size preview, int sensor, boolean front, int display) {
        boolean swapsAxes = (sensor - display * (front ? 1 : -1) + 360) % 180 != 0;
        float scaleX, scaleY;
        if (sensor % 180 == 0) {
            scaleX = (float) width / (swapsAxes ? preview.getWidth() : preview.getHeight());
            scaleY = (float) height / (swapsAxes ? preview.getHeight() : preview.getWidth());
        } else {
            scaleX = (float) width / (swapsAxes ? preview.getHeight() : preview.getWidth());
            scaleY = (float) height / (swapsAxes ? preview.getWidth() : preview.getHeight());
        }
        float fill = Math.max(scaleX, scaleY), cx = width / 2f, cy = height / 2f;
        Matrix matrix = new Matrix();
        if (swapsAxes) matrix.setScale(fill / scaleX, fill / scaleY, cx, cy);
        else matrix.setScale((float) height / width / scaleY * fill,
                (float) width / height / scaleX * fill, cx, cy);
        matrix.postRotate(-display, cx, cy);
        if (front) matrix.postScale(-1, 1, cx, cy);
        return matrix;
    }

    void begin() {
        recordingId++; frames.clear(); collecting = true; draining = false; lastSampleAt = 0;
        main.removeCallbacks(periodic);
        if (isReady()) sampleNow(); // Otherwise the first preview frame starts sampling immediately.

    }
    private final Runnable periodic = new Runnable() {
        public void run() { if (collecting && !closed) sampleNow(); }
    };
    private void scheduleNextSample() {
        main.removeCallbacks(periodic);
        if (collecting && !closed && frames.size() < MAX_CAPTURED_FRAMES) {
            long remaining = SAMPLE_INTERVAL_MS - (android.os.SystemClock.elapsedRealtime() - lastSampleAt);
            main.postDelayed(periodic, Math.max(1, remaining));
        }
    }
    private void sampleNow() {
        if (closed || !configured || !isReady() || inFlight || session == null || frames.size() >= MAX_CAPTURED_FRAMES) return;
        long now = android.os.SystemClock.elapsedRealtime();
        if (lastSampleAt != 0 && now - lastSampleAt < SAMPLE_INTERVAL_MS) { scheduleNextSample(); return; }
        lastSampleAt = now;
        try {
            CaptureRequest.Builder request = device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);
            request.addTarget(reader.getSurface());
            request.set(CaptureRequest.CONTROL_AF_MODE, focusMode);
            request.set(CaptureRequest.JPEG_ORIENTATION,
                    (orientation + (front ? rotationDegrees() : -rotationDegrees()) + 360) % 360);
            request.setTag(recordingId); flightId = recordingId; inFlight = true;
            session.capture(request.build(), new CameraCaptureSession.CaptureCallback() {
                @Override public void onCaptureFailed(CameraCaptureSession session, CaptureRequest request,
                                                       CaptureFailure failure) {
                    inFlight = false;
                    if (!closed) {
                        error.accept("本次画面未能拍摄，原音仍在继续保存");
                        if (draining) completeFinish(); else scheduleNextSample();
                    }
                }
            }, main);
            scheduleNextSample();
        } catch (Exception e) {
            inFlight = false;
            error.accept("本次画面未能拍摄，原音仍在继续保存");
            if (draining) completeFinish(); else scheduleNextSample();
        }
    }
    private void receiveImage(ImageReader source) {
        if (closed) return;
        boolean received = false;
        try (Image image = source.acquireLatestImage()) {
            if (image == null) return;
            received = true;
            if ((collecting || draining) && flightId == recordingId && frames.size() < MAX_CAPTURED_FRAMES) {
                ByteBuffer buffer = image.getPlanes()[0].getBuffer();
                byte[] bytes = new byte[buffer.remaining()]; buffer.get(bytes); frames.add(bytes);
            }
        } catch (IllegalStateException e) {
            if (!closed) error.accept("本次画面未能读取，原音已保留");
        } finally {
            if (received) {
                inFlight = false;
                if (draining) completeFinish();
                else if (collecting) scheduleNextSample();
            }
        }
    }

    void finish(Consumer<List<byte[]>> callback) {
        main.removeCallbacks(periodic);
        if (frames.isEmpty() && collecting && !inFlight && isReady()) sampleNow();
        collecting = false; draining = true; finishCallback = callback;
        if (inFlight) main.postDelayed(finishTimeout, 1200); else completeFinish();
    }
    private final Runnable finishTimeout = this::completeFinish;
    private void completeFinish() {
        main.removeCallbacks(finishTimeout);
        Consumer<List<byte[]>> callback = finishCallback; finishCallback = null; draining = false;
        List<byte[]> result = evenlySelected(frames, MAX_REVIEW_FRAMES); frames.clear();
        if (callback != null) callback.accept(result);
    }
    static <T> List<T> evenlySelected(List<T> frames, int maximum) {
        if (maximum <= 0) return new ArrayList<>();
        if (frames.size() <= maximum) return new ArrayList<>(frames);
        List<T> selected = new ArrayList<>();
        for (int i = 0; i < maximum; i++) selected.add(frames.get(i * (frames.size() - 1) / Math.max(1, maximum - 1)));
        return selected;
    }
    void cancel() { collecting = false; recordingId++; frames.clear(); main.removeCallbacks(periodic); }
    private void fail(String message) {
        android.util.Log.w("PointVerseCamera",message);
        opening = false; configured = false;
        setState(State.FAILED); error.accept(message);
        if (draining) completeFinish();
    }
    void close() {
        if (closed) return;
        closed = true; collecting = false; configured = false;
        main.removeCallbacks(periodic); main.removeCallbacks(finishTimeout);
        if (session != null) session.close();
        if (device != null) device.close();
        if (reader != null) reader.close();
        if (preview != null) preview.release();
        session = null; device = null; reader = null; preview = null;
        setState(State.CLOSED);
        if (finishCallback != null) completeFinish(); else frames.clear();
    }
}

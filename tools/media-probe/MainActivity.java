package com.neonews.runtime.mediaprobe;

import android.app.Activity;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.URL;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public final class MainActivity extends Activity {
    private static final int MAX_BYTES = 1024 * 1024;
    private Handler mainHandler;
    private File resultFile;
    private File cacheFile;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        mainHandler = new Handler(Looper.getMainLooper());
        resultFile = new File(getFilesDir(), "media-result.txt");
        cacheFile = new File(getFilesDir(), "network-cache.bin");
        deleteQuietly(resultFile);
        setContentView(new TextView(this));

        final boolean offline = getIntent().getBooleanExtra("offline", false);
        final String httpUrl = valueOrDefault(getIntent().getStringExtra("httpUrl"), "http://example.com");
        final String httpsUrl = valueOrDefault(getIntent().getStringExtra("httpsUrl"), "https://example.com");
        final String hlsUrl = valueOrDefault(getIntent().getStringExtra("hlsUrl"), "");
        final int delayMs = getIntent().getIntExtra("delayMs", 0);
        new Thread(new Runnable() {
            @Override
            public void run() {
                if (delayMs > 0) {
                    try { Thread.sleep(delayMs); } catch (InterruptedException ignored) { }
                }
                if (offline) runOffline(httpsUrl);
                else runOnline(httpUrl, httpsUrl, hlsUrl);
            }
        }, "media-probe").start();
    }

    private void runOnline(String httpUrl, String httpsUrl, String hlsUrl) {
        FetchResult http = fetch(httpUrl, false, false);
        FetchResult https = fetch(httpsUrl, true, true);
        boolean cacheReady = cacheFile.exists() && cacheFile.length() > 0;
        FetchResult playlist = fetch(hlsUrl, true, false);
        boolean playlistValid = playlist.ok && playlist.text != null && playlist.text.contains("#EXTM3U");
        HlsResult hls = playlistValid ? playHls(hlsUrl) : new HlsResult(false, false, playlist.error);
        boolean status = http.ok && https.ok && cacheReady && playlistValid && hls.playable;
        writeResult("status=" + (status ? "ok" : "error")
                + ";dns=" + (http.dns && https.dns)
                + ";http=" + http.ok
                + ";https=" + https.ok
                + ";cache=" + cacheReady
                + ";hlsPlaylist=" + playlistValid
                + ";hlsPlayable=" + hls.playable
                + ";hlsError=" + sanitize(hls.error));
    }

    private void runOffline(String httpsUrl) {
        boolean cacheReady = cacheFile.exists() && cacheFile.length() > 0;
        FetchResult network = fetch(httpsUrl, true, false);
        boolean networkUnavailable = !network.ok;
        boolean status = cacheReady && networkUnavailable;
        writeResult("status=" + (status ? "ok" : "error")
                + ";cachedContent=" + cacheReady
                + ";networkUnavailable=" + networkUnavailable
                + ";networkAttempt=" + sanitize(network.error));
    }

    private FetchResult fetch(String target, boolean requireHttps, boolean saveCache) {
        if (target == null || target.length() == 0) return new FetchResult(false, false, "", "missing-url");
        try {
            URL url = new URL(target);
            if (requireHttps && !"https".equalsIgnoreCase(url.getProtocol())) return new FetchResult(false, false, "", "not-https");
            InetAddress address = InetAddress.getByName(url.getHost());
            HttpURLConnection connection = (HttpURLConnection) url.openConnection();
            connection.setConnectTimeout(15000);
            connection.setReadTimeout(20000);
            connection.setInstanceFollowRedirects(true);
            int response = connection.getResponseCode();
            InputStream input = response >= 400 ? connection.getErrorStream() : connection.getInputStream();
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            if (input != null) {
                byte[] buffer = new byte[8192];
                int read;
                int total = 0;
                while ((read = input.read(buffer)) != -1 && total < MAX_BYTES) {
                    bytes.write(buffer, 0, read);
                    total += read;
                }
                input.close();
            }
            connection.disconnect();
            byte[] body = bytes.toByteArray();
            boolean ok = response >= 200 && response < 400 && body.length > 0;
            if (ok && saveCache) writeBytes(cacheFile, body);
            String text = new String(body, "UTF-8");
            return new FetchResult(ok, true, text, ok ? "" : "http-" + response);
        } catch (Exception exception) {
            return new FetchResult(false, false, "", exception.getClass().getSimpleName() + ":" + exception.getMessage());
        }
    }

    private HlsResult playHls(final String hlsUrl) {
        final CountDownLatch done = new CountDownLatch(1);
        final AtomicBoolean prepared = new AtomicBoolean(false);
        final AtomicBoolean playing = new AtomicBoolean(false);
        final AtomicBoolean error = new AtomicBoolean(false);
        final String[] errorText = new String[] { "" };
        final MediaPlayer[] holder = new MediaPlayer[1];
        mainHandler.post(new Runnable() {
            @Override
            public void run() {
                try {
                    final MediaPlayer player = new MediaPlayer();
                    holder[0] = player;
                    player.setOnPreparedListener(new MediaPlayer.OnPreparedListener() {
                        @Override
                        public void onPrepared(final MediaPlayer mediaPlayer) {
                            prepared.set(true);
                            try { mediaPlayer.start(); }
                            catch (Exception exception) { error.set(true); errorText[0] = exception.toString(); done.countDown(); return; }
                            mainHandler.postDelayed(new Runnable() {
                                @Override
                                public void run() {
                                    try { playing.set(mediaPlayer.isPlaying()); }
                                    catch (Exception exception) { error.set(true); errorText[0] = exception.toString(); }
                                    release(mediaPlayer);
                                    done.countDown();
                                }
                            }, 4000);
                        }
                    });
                    player.setOnErrorListener(new MediaPlayer.OnErrorListener() {
                        @Override
                        public boolean onError(MediaPlayer mediaPlayer, int what, int extra) {
                            error.set(true);
                            errorText[0] = "media-error:" + what + ":" + extra;
                            release(mediaPlayer);
                            done.countDown();
                            return true;
                        }
                    });
                    player.setDataSource(MainActivity.this, Uri.parse(hlsUrl));
                    player.prepareAsync();
                } catch (Exception exception) {
                    error.set(true);
                    errorText[0] = exception.toString();
                    done.countDown();
                }
            }
        });
        try { done.await(25000, TimeUnit.MILLISECONDS); }
        catch (InterruptedException exception) { error.set(true); errorText[0] = exception.toString(); }
        if (holder[0] != null && !prepared.get() && !error.get()) {
            final MediaPlayer player = holder[0];
            mainHandler.post(new Runnable() { @Override public void run() { release(player); } });
            error.set(true);
            errorText[0] = "media-timeout";
        }
        return new HlsResult(prepared.get(), prepared.get() && playing.get() && !error.get(), errorText[0]);
    }

    private static void release(MediaPlayer player) {
        try { player.stop(); } catch (Exception ignored) { }
        try { player.release(); } catch (Exception ignored) { }
    }

    private void writeResult(String value) {
        try {
            FileOutputStream output = new FileOutputStream(resultFile);
            output.write(value.getBytes("UTF-8"));
            output.close();
        } catch (Exception ignored) { }
        finish();
    }

    private static void writeBytes(File file, byte[] bytes) {
        try {
            FileOutputStream output = new FileOutputStream(file);
            output.write(bytes);
            output.close();
        } catch (Exception ignored) { }
    }

    private static String valueOrDefault(String value, String fallback) {
        return value == null || value.length() == 0 ? fallback : value;
    }

    private static String sanitize(String value) {
        return value == null ? "" : value.replace(';', ',').replace('\n', ' ').replace('\r', ' ');
    }

    private static void deleteQuietly(File file) {
        if (file.exists()) file.delete();
    }

    private static final class FetchResult {
        final boolean ok;
        final boolean dns;
        final String text;
        final String error;

        FetchResult(boolean ok, boolean dns, String text, String error) {
            this.ok = ok;
            this.dns = dns;
            this.text = text;
            this.error = error;
        }
    }

    private static final class HlsResult {
        final boolean prepared;
        final boolean playable;
        final String error;

        HlsResult(boolean prepared, boolean playable, String error) {
            this.prepared = prepared;
            this.playable = playable;
            this.error = error;
        }
    }
}

package com.neonews.runtime.webviewprobe;

import android.app.Activity;
import android.net.http.SslError;
import android.os.Bundle;
import android.webkit.SslErrorHandler;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.ValueCallback;

import java.io.File;
import java.io.FileOutputStream;

public final class MainActivity extends Activity {
    private static final String LOCAL_BASE_URL = "https://neonews-runtime.local/";
    private static final String LOCAL_HTML = "<html><head><style>#probe{color:rgb(0,255,0)}</style>"
            + "<script>function probe(){return 'js-ok|' + getComputedStyle(document.getElementById('probe')).color;}</script>"
            + "</head><body><div id='probe'>NeoNews WebView Probe</div></body></html>";
    private static final String LOCAL_PROBE_SCRIPT = "(function(){"
            + "var text=document.body && document.body.innerText || '';"
            + "var color=getComputedStyle(document.getElementById('probe')).color;"
            + "return 'html='+(text.indexOf('NeoNews WebView Probe') >= 0)"
            + "+'|css='+color+'|'+probe();"
            + "})()";

    private WebView webView;
    private File resultFile;
    private String remoteUrl;
    private boolean localChecked;
    private boolean completed;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        resultFile = new File(getFilesDir(), "webview-result.txt");
        if (resultFile.exists()) resultFile.delete();
        remoteUrl = getIntent().getStringExtra("url");
        if (remoteUrl == null || remoteUrl.length() == 0) remoteUrl = "https://example.com";

        webView = new WebView(this);
        webView.getSettings().setJavaScriptEnabled(true);
        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(final WebView view, final String url) {
                if (!localChecked && url != null && url.startsWith(LOCAL_BASE_URL)) {
                    view.evaluateJavascript("document.title='NeoNews local';" + LOCAL_PROBE_SCRIPT, new ValueCallback<String>() {
                        @Override
                        public void onReceiveValue(String value) {
                            String normalized = value == null ? "" : value.replace(" ", "").toLowerCase();
                            boolean localHtml = normalized.contains("html=true");
                            boolean localCss = normalized.contains("css=rgb(0,255,0)");
                            boolean localJs = normalized.contains("js-ok");
                            localChecked = true;
                            getPreferences(MODE_PRIVATE).edit()
                                    .putBoolean("localHtml", localHtml)
                                    .putBoolean("localCss", localCss)
                                    .putBoolean("localJs", localJs)
                                    .apply();
                            view.loadUrl(remoteUrl);
                        }
                    });
                    return;
                }

                if (localChecked && url != null && url.startsWith("https://")) {
                    view.evaluateJavascript("(function(){return location.protocol + '|length=' + ((document.body && document.body.innerText) || '').length;})()", new ValueCallback<String>() {
                        @Override
                        public void onReceiveValue(String value) {
                            String normalized = value == null ? "" : value.replace(" ", "").toLowerCase();
                            boolean remoteHttps = normalized.startsWith("\"https:");
                            boolean remoteContent = normalized.matches(".*\\|length=[1-9][0-9]*\\\"$");
                            boolean localHtml = getPreferences(MODE_PRIVATE).getBoolean("localHtml", false);
                            boolean localCss = getPreferences(MODE_PRIVATE).getBoolean("localCss", false);
                            boolean localJs = getPreferences(MODE_PRIVATE).getBoolean("localJs", false);
                            writeResult("status=" + (localHtml && localCss && localJs && remoteHttps && remoteContent ? "ok" : "error")
                                    + ";localHtml=" + localHtml + ";localCss=" + localCss + ";localJs=" + localJs
                                    + ";remoteHttps=" + remoteHttps + ";remoteContent=" + remoteContent + ";url=" + url);
                        }
                    });
                }
            }

            @Override
            public void onReceivedSslError(WebView view, SslErrorHandler handler, SslError error) {
                handler.cancel();
                writeResult("status=error;detail=ssl-error");
            }

            @Override
            public void onReceivedError(WebView view, int errorCode, String description, String failingUrl) {
                writeResult("status=error;detail=" + description + ";url=" + failingUrl);
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request != null && request.isForMainFrame()) {
                    writeResult("status=error;detail=resource-error;url=" + request.getUrl());
                }
            }
        });
        setContentView(webView);
        webView.loadDataWithBaseURL(LOCAL_BASE_URL, LOCAL_HTML, "text/html", "UTF-8", null);
    }

    private void writeResult(String value) {
        if (completed) return;
        completed = true;
        try {
            FileOutputStream output = new FileOutputStream(resultFile);
            output.write(value.getBytes("UTF-8"));
            output.close();
        } catch (Exception ignored) {
        }
        finish();
    }
}

package com.neonews.runtime.ttsprobe;

import android.app.Activity;
import android.os.Bundle;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Locale;

public final class MainActivity extends Activity {
    private static final String TEXT = "Teste de voz do NeoNews Runtime.";
    private TextToSpeech textToSpeech;
    private File resultFile;
    private File audioFile;
    private boolean speakDone;
    private boolean synthesisDone;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        resultFile = new File(getFilesDir(), "tts-result.txt");
        audioFile = new File(getFilesDir(), "tts.wav");
        deleteQuietly(resultFile);
        deleteQuietly(audioFile);
        textToSpeech = new TextToSpeech(this, new TextToSpeech.OnInitListener() {
            @Override
            public void onInit(int status) {
                initialize(status);
            }
        });
    }

    private void initialize(int status) {
        if (status != TextToSpeech.SUCCESS) {
            finishWithError("engine-init-failed:" + status);
            return;
        }

        final Locale locale = new Locale("pt", "BR");
        final int languageStatus = textToSpeech.setLanguage(locale);
        if (languageStatus == TextToSpeech.LANG_MISSING_DATA || languageStatus == TextToSpeech.LANG_NOT_SUPPORTED) {
            finishWithError("locale-unavailable:" + languageStatus);
            return;
        }

        textToSpeech.setOnUtteranceProgressListener(new UtteranceProgressListener() {
            @Override
            public void onStart(String utteranceId) {
            }

            @Override
            public void onDone(String utteranceId) {
                if ("speak".equals(utteranceId)) speakDone = true;
                if ("synthesis".equals(utteranceId)) synthesisDone = true;
                if (speakDone && synthesisDone) {
                    writeResult("status=ok;engine=" + textToSpeech.getDefaultEngine() + ";locale=pt-BR");
                }
            }

            @Override
            public void onError(String utteranceId) {
                finishWithError("utterance-error:" + utteranceId);
            }

            @Override
            public void onError(String utteranceId, int errorCode) {
                finishWithError("utterance-error:" + utteranceId + ":" + errorCode);
            }
        });

        Bundle params = new Bundle();
        params.putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, "speak");
        int speakStatus = textToSpeech.speak(TEXT, TextToSpeech.QUEUE_FLUSH, params, "speak");
        int synthesisStatus = textToSpeech.synthesizeToFile(TEXT, null, audioFile, "synthesis");
        if (synthesisStatus != TextToSpeech.SUCCESS || speakStatus != TextToSpeech.SUCCESS) {
            finishWithError("request-failed:synthesis=" + synthesisStatus + ",speak=" + speakStatus);
        }
    }

    private void finishWithError(String detail) {
        writeResult("status=error;detail=" + detail);
    }

    private void writeResult(String value) {
        if (resultFile.exists()) return;
        try {
            FileOutputStream output = new FileOutputStream(resultFile);
            output.write(value.getBytes("UTF-8"));
            output.close();
        } catch (IOException ignored) {
        }
        if (textToSpeech != null) textToSpeech.shutdown();
        finish();
    }

    private static void deleteQuietly(File file) {
        if (file.exists()) file.delete();
    }
}

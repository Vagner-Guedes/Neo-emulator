import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Small diagnostic/provisioning relay for Android-x86 guests whose API 25
 * adbd only exposes an IPv6 listener. It accepts IPv4 on one port and copies
 * both directions to the IPv6 adbd endpoint.
 */
public final class AdbIpv4Relay {
    private static final int CONNECT_TIMEOUT_MS = 3000;

    private AdbIpv4Relay() {
    }

    public static void main(String[] args) throws Exception {
        int listenPort = args.length > 0 ? Integer.parseInt(args[0]) : 5555;
        String targetHost = args.length > 1 ? args[1] : "::1";
        int targetPort = args.length > 2 ? Integer.parseInt(args[2]) : 5556;

        ServerSocket listener = new ServerSocket();
        listener.setReuseAddress(true);
        listener.bind(new InetSocketAddress(InetAddress.getByName("0.0.0.0"), listenPort), 16);

        while (true) {
            Socket client = listener.accept();
            bridge(client, targetHost, targetPort);
        }
    }

    private static void bridge(final Socket client, String targetHost, int targetPort) {
        final Socket target = new Socket();
        try {
            target.connect(new InetSocketAddress(InetAddress.getByName(targetHost), targetPort), CONNECT_TIMEOUT_MS);
            startPipe(client, target, "adb-relay-client-to-target");
            startPipe(target, client, "adb-relay-target-to-client");
        } catch (IOException error) {
            close(client);
            close(target);
        }
    }

    private static void startPipe(final Socket source, final Socket destination, String name) {
        Thread pipe = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    copy(source.getInputStream(), destination.getOutputStream());
                } catch (IOException ignored) {
                    // Closing either side terminates the paired stream.
                } finally {
                    close(source);
                    close(destination);
                }
            }
        }, name);
        pipe.setDaemon(true);
        pipe.start();
    }

    private static void copy(InputStream input, OutputStream output) throws IOException {
        byte[] buffer = new byte[8192];
        int count;
        while ((count = input.read(buffer)) != -1) {
            output.write(buffer, 0, count);
            output.flush();
        }
    }

    private static void close(Socket socket) {
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }
}

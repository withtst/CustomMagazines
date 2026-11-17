package org.mypzmods.custommagazines;

import se.krka.kahlua.integration.annotations.LuaMethod;
import org.glavo.webp.WebPFrame;
import org.glavo.webp.WebPImageLoadOptions;
import org.glavo.webp.WebPImageReader;

import javax.imageio.ImageIO;
import javax.imageio.ImageReader;
import javax.imageio.stream.ImageInputStream;
import java.awt.Graphics2D;
import java.awt.RenderingHints;
import java.awt.image.BufferedImage;
import java.awt.image.DataBufferInt;
import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Small, path-constrained bridge for the Lua reader. */
public final class CustomMagazinesJava {
    private static final long MAX_FILE_BYTES = 64L * 1024L * 1024L;
    private static final long MAX_IMAGE_PIXELS = 24_000_000L;
    private static final int MAX_SOURCE_EDGE = 16_000;
    private static final int MAX_TEXTURE_WIDTH = 1_800;
    private static final int MAX_TEXTURE_HEIGHT = 2_400;
    private static final Set<String> EXTENSIONS = Set.of("jpg", "jpeg", "png", "webp");

    private static final Map<String, Object> activeTextures = new HashMap<>();

    public CustomMagazinesJava() {
    }

    @LuaMethod(name = "CMListFolders", global = true)
    public static ArrayList<String> listFolders(String rootText) {
        ArrayList<String> result = new ArrayList<>();
        for (String folder : listFolderNames(rootText)) {
            if (!listImages(rootText, folder).isEmpty()) result.add(folder);
        }
        return result;
    }

    @LuaMethod(name = "CMListFolderNames", global = true)
    public static ArrayList<String> listFolderNames(String rootText) {
        ArrayList<String> result = new ArrayList<>();
        Path root = canonicalRoot(rootText);
        if (root == null) return result;
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(root)) {
            for (Path entry : entries) {
                if (Files.isSymbolicLink(entry) || !Files.isDirectory(entry, LinkOption.NOFOLLOW_LINKS)) continue;
                Path folder = canonicalDirectChild(root, entry.getFileName().toString(), true);
                if (folder != null) result.add(entry.getFileName().toString());
            }
        } catch (IOException ignored) {
            return result;
        }
        result.sort(STRING_NAME_ORDER);
        return result;
    }

    @LuaMethod(name = "CMListImages", global = true)
    public static ArrayList<String> listImages(String rootText, String folderName) {
        ArrayList<String> result = new ArrayList<>();
        Path root = canonicalRoot(rootText);
        if (root == null) return result;
        Path folder = canonicalDirectChild(root, folderName, true);
        if (folder == null) return result;

        try (DirectoryStream<Path> entries = Files.newDirectoryStream(folder)) {
            for (Path entry : entries) {
                if (Files.isSymbolicLink(entry) || !Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) continue;
                Path file = canonicalDirectChild(folder, entry.getFileName().toString(), false);
                if (file == null || !isAllowedImage(file) || !isReadableImage(file)) continue;
                result.add(entry.getFileName().toString());
            }
        } catch (IOException ignored) {
            return result;
        }
        result.sort(STRING_NAME_ORDER);
        return result;
    }

    @LuaMethod(name = "CMDefaultTitle", global = true)
    public static String defaultTitle(String folderName) {
        if (folderName == null || folderName.isEmpty()) return "Magazine";
        StringBuilder title = new StringBuilder();
        int count = 0;
        for (int offset = 0; offset < folderName.length() && count < 4;) {
            int codePoint = folderName.codePointAt(offset);
            offset += Character.charCount(codePoint);
            Character.UnicodeScript script = Character.UnicodeScript.of(codePoint);
            if (script != Character.UnicodeScript.HAN && script != Character.UnicodeScript.LATIN) continue;
            title.appendCodePoint(codePoint);
            count++;
        }
        return title.isEmpty() ? "Magazine" : title.toString();
    }

    @LuaMethod(name = "CMSanitizeTitle", global = true)
    public static String sanitizeTitle(String rawTitle) {
        if (rawTitle == null) return "";
        StringBuilder title = new StringBuilder();
        int count = 0;
        for (int offset = 0; offset < rawTitle.length() && count < 32;) {
            int codePoint = rawTitle.codePointAt(offset);
            offset += Character.charCount(codePoint);
            if (Character.isISOControl(codePoint)) continue;
            title.appendCodePoint(codePoint);
            count++;
        }
        return title.toString().strip();
    }

    @LuaMethod(name = "CMLoadTexture", global = true)
    public static synchronized Object loadTexture(String rootText, String folderName, String fileName, String ownerKey) {
        if (ownerKey == null || ownerKey.isBlank()) return null;
        releaseTexture(ownerKey);
        Path root = canonicalRoot(rootText);
        if (root == null) return null;
        Path folder = canonicalDirectChild(root, folderName, true);
        if (folder == null) return null;
        Path file = canonicalDirectChild(folder, fileName, false);
        if (file == null || !isAllowedImage(file) || !isReadableImage(file)) return null;

        BufferedImage source = null;
        BufferedImage scaled = null;
        try {
            if (Files.size(file) > MAX_FILE_BYTES) return null;
            source = decodeImage(file);
            if (source == null) return null;
            int width = source.getWidth();
            int height = source.getHeight();
            if (!validDimensions(width, height)) return null;

            double scale = Math.min(1.0, Math.min(
                    MAX_TEXTURE_WIDTH / (double) width,
                    MAX_TEXTURE_HEIGHT / (double) height));
            int targetWidth = Math.max(1, (int) Math.round(width * scale));
            int targetHeight = Math.max(1, (int) Math.round(height * scale));
            scaled = new BufferedImage(targetWidth, targetHeight, BufferedImage.TYPE_INT_ARGB);
            Graphics2D graphics = scaled.createGraphics();
            graphics.setRenderingHint(RenderingHints.KEY_INTERPOLATION, RenderingHints.VALUE_INTERPOLATION_BILINEAR);
            graphics.setRenderingHint(RenderingHints.KEY_RENDERING, RenderingHints.VALUE_RENDER_QUALITY);
            graphics.drawImage(source, 0, 0, targetWidth, targetHeight, null);
            graphics.dispose();

            int[] argb = scaled.getRGB(0, 0, targetWidth, targetHeight, null, 0, targetWidth);
            ByteBuffer rgba = ByteBuffer.allocateDirect(targetWidth * targetHeight * 4);
            for (int pixel : argb) {
                rgba.put((byte) ((pixel >>> 16) & 0xff));
                rgba.put((byte) ((pixel >>> 8) & 0xff));
                rgba.put((byte) (pixel & 0xff));
                rgba.put((byte) ((pixel >>> 24) & 0xff));
            }
            rgba.flip();

            Class<?> textureIdClass = Class.forName("zombie.core.textures.TextureID");
            Object textureId = textureIdClass.getConstructor(int.class, int.class, ByteBuffer.class)
                    .newInstance(targetWidth, targetHeight, rgba);
            Class<?> textureClass = Class.forName("zombie.core.textures.Texture");
            Object texture = textureClass.getConstructor(textureIdClass, String.class)
                    .newInstance(textureId, "CustomMagazines:" + Integer.toHexString(System.identityHashCode(textureId)));
            activeTextures.put(ownerKey, texture);
            return texture;
        } catch (Throwable ignored) {
            releaseTexture(ownerKey);
            return null;
        } finally {
            if (source != null) source.flush();
            if (scaled != null) scaled.flush();
        }
    }

    @LuaMethod(name = "CMReleaseTexture", global = true)
    public static synchronized void releaseTexture(String ownerKey) {
        if (ownerKey == null) return;
        Object texture = activeTextures.remove(ownerKey);
        destroyTexture(texture);
    }

    @LuaMethod(name = "CMReleaseAllTextures", global = true)
    public static synchronized void releaseAllTextures() {
        for (Object texture : activeTextures.values()) destroyTexture(texture);
        activeTextures.clear();
    }

    private static void destroyTexture(Object texture) {
        if (texture == null) return;
        try {
            texture.getClass().getMethod("destroy").invoke(texture);
        } catch (Throwable ignored) {
            // Texture may already have been released during game shutdown.
        }
    }

    private static final Comparator<String> STRING_NAME_ORDER = Comparator
            .comparing((String name) -> name, String.CASE_INSENSITIVE_ORDER)
            .thenComparing(name -> name);

    private static Path canonicalRoot(String rootText) {
        if (rootText == null || rootText.isBlank()) return null;
        try {
            Path configured = Paths.get(rootText.trim());
            if (!configured.isAbsolute()) return null;
            Path root = configured.normalize().toRealPath();
            return Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) ? root : null;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static Path canonicalDirectChild(Path parent, String childName, boolean directory) {
        if (parent == null || childName == null || childName.isBlank()) return null;
        try {
            Path name = Paths.get(childName);
            if (name.isAbsolute() || name.getNameCount() != 1 || childName.equals(".") || childName.equals("..")) return null;
            Path candidate = parent.resolve(name).normalize();
            if (!parent.equals(candidate.getParent()) || Files.isSymbolicLink(candidate)) return null;
            if (directory && !Files.isDirectory(candidate, LinkOption.NOFOLLOW_LINKS)) return null;
            if (!directory && !Files.isRegularFile(candidate, LinkOption.NOFOLLOW_LINKS)) return null;
            Path real = candidate.toRealPath(LinkOption.NOFOLLOW_LINKS);
            if (!parent.equals(real.getParent())) return null;
            return real;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static boolean isAllowedImage(Path file) {
        String name = file.getFileName().toString();
        int dot = name.lastIndexOf('.');
        if (dot < 0 || dot == name.length() - 1) return false;
        return EXTENSIONS.contains(name.substring(dot + 1).toLowerCase(Locale.ROOT));
    }

    private static boolean isReadableImage(Path file) {
        try {
            if (Files.size(file) > MAX_FILE_BYTES) return false;
            if (isWebP(file)) {
                int[] dimensions = readWebPDimensions(file);
                return dimensions != null && validDimensions(dimensions[0], dimensions[1]);
            }
            try (ImageInputStream input = ImageIO.createImageInputStream(file.toFile())) {
                if (input == null) return false;
                Iterator<ImageReader> readers = ImageIO.getImageReaders(input);
                if (!readers.hasNext()) return false;
                ImageReader reader = readers.next();
                try {
                    reader.setInput(input, true, true);
                    return validDimensions(reader.getWidth(0), reader.getHeight(0));
                } finally {
                    reader.dispose();
                }
            }
        } catch (Exception ignored) {
            return false;
        }
    }

    static BufferedImage decodeImage(Path file) throws IOException {
        if (isWebP(file)) return decodeWebP(file);
        return ImageIO.read(file.toFile());
    }

    private static BufferedImage decodeWebP(Path file) throws IOException {
        int[] dimensions = readWebPDimensions(file);
        if (dimensions == null || !validDimensions(dimensions[0], dimensions[1])) return null;

        double scale = Math.min(1.0, Math.min(
                MAX_TEXTURE_WIDTH / (double) dimensions[0],
                MAX_TEXTURE_HEIGHT / (double) dimensions[1]));
        int requestedWidth = Math.max(1, (int) Math.round(dimensions[0] * scale));
        int requestedHeight = Math.max(1, (int) Math.round(dimensions[1] * scale));
        WebPImageLoadOptions options = new WebPImageLoadOptions(requestedWidth, requestedHeight, true, true);

        try (WebPImageReader reader = WebPImageReader.open(file, options)) {
            if (reader.getSourceWidth() != dimensions[0] || reader.getSourceHeight() != dimensions[1]) return null;
            WebPFrame frame = reader.readNextFrame();
            if (frame == null || !validDimensions(frame.getWidth(), frame.getHeight())) return null;

            BufferedImage image = new BufferedImage(frame.getWidth(), frame.getHeight(), BufferedImage.TYPE_INT_ARGB);
            int[] pixels = ((DataBufferInt) image.getRaster().getDataBuffer()).getData();
            IntBuffer argb = frame.getArgbPixels();
            if (argb.remaining() != pixels.length) {
                image.flush();
                return null;
            }
            argb.get(pixels);
            return image;
        }
    }

    private static boolean isWebP(Path file) {
        String name = file.getFileName().toString();
        int dot = name.lastIndexOf('.');
        return dot >= 0 && dot < name.length() - 1 && name.substring(dot + 1).equalsIgnoreCase("webp");
    }

    /** Reads the bounded RIFF/WebP header only; pixel decoding is deferred until the page is opened. */
    private static int[] readWebPDimensions(Path file) {
        try {
            long fileSize = Files.size(file);
            if (fileSize < 20 || fileSize > MAX_FILE_BYTES) return null;
            try (DataInputStream input = new DataInputStream(new BufferedInputStream(Files.newInputStream(file)))) {
                byte[] header = new byte[12];
                input.readFully(header);
                if (!asciiEquals(header, 0, "RIFF") || !asciiEquals(header, 8, "WEBP")) return null;

                long riffLength = uint32LE(header, 4);
                long end = riffLength + 8L;
                if (riffLength < 4 || end > fileSize) return null;

                long position = 12;
                byte[] chunkHeader = new byte[8];
                while (position + 8 <= end) {
                    input.readFully(chunkHeader);
                    position += 8;
                    long chunkLength = uint32LE(chunkHeader, 4);
                    long paddedLength = chunkLength + (chunkLength & 1L);
                    if (chunkLength > MAX_FILE_BYTES || position + paddedLength > end) return null;

                    if (asciiEquals(chunkHeader, 0, "VP8X")) {
                        if (chunkLength < 10) return null;
                        byte[] data = new byte[10];
                        input.readFully(data);
                        int width = 1 + uint24LE(data, 4);
                        int height = 1 + uint24LE(data, 7);
                        return new int[]{width, height};
                    }

                    if (asciiEquals(chunkHeader, 0, "VP8L")) {
                        if (chunkLength < 5) return null;
                        byte[] data = new byte[5];
                        input.readFully(data);
                        if ((data[0] & 0xff) != 0x2f) return null;
                        int b1 = data[1] & 0xff;
                        int b2 = data[2] & 0xff;
                        int b3 = data[3] & 0xff;
                        int b4 = data[4] & 0xff;
                        int width = 1 + b1 + ((b2 & 0x3f) << 8);
                        int height = 1 + (b2 >>> 6) + (b3 << 2) + ((b4 & 0x0f) << 10);
                        return new int[]{width, height};
                    }

                    if (asciiEquals(chunkHeader, 0, "VP8 ")) {
                        if (chunkLength < 10) return null;
                        byte[] data = new byte[10];
                        input.readFully(data);
                        if ((data[3] & 0xff) != 0x9d || (data[4] & 0xff) != 0x01 || (data[5] & 0xff) != 0x2a) return null;
                        int width = ((data[6] & 0xff) | ((data[7] & 0xff) << 8)) & 0x3fff;
                        int height = ((data[8] & 0xff) | ((data[9] & 0xff) << 8)) & 0x3fff;
                        return new int[]{width, height};
                    }

                    input.skipNBytes(paddedLength);
                    position += paddedLength;
                }
            }
        } catch (Exception ignored) {
            return null;
        }
        return null;
    }

    private static boolean asciiEquals(byte[] data, int offset, String expected) {
        if (offset < 0 || offset + expected.length() > data.length) return false;
        for (int i = 0; i < expected.length(); i++) {
            if ((data[offset + i] & 0xff) != expected.charAt(i)) return false;
        }
        return true;
    }

    private static long uint32LE(byte[] data, int offset) {
        return (data[offset] & 0xffL)
                | ((data[offset + 1] & 0xffL) << 8)
                | ((data[offset + 2] & 0xffL) << 16)
                | ((data[offset + 3] & 0xffL) << 24);
    }

    private static int uint24LE(byte[] data, int offset) {
        return (data[offset] & 0xff)
                | ((data[offset + 1] & 0xff) << 8)
                | ((data[offset + 2] & 0xff) << 16);
    }

    private static boolean validDimensions(int width, int height) {
        if (width <= 0 || height <= 0 || width > MAX_SOURCE_EDGE || height > MAX_SOURCE_EDGE) return false;
        return (long) width * (long) height <= MAX_IMAGE_PIXELS;
    }
}

// Known-answer probe: opens one document through Okular::Document and prints what it parsed, so
// test.sh can compare the output against exact expected values.
#include <QApplication>
#include <QDir>
#include <QImage>
#include <QMimeDatabase>
#include <QPixmap>
#include <QTemporaryDir>
#include <KPluginMetaData>
#include <QUrl>

#include <cstdio>
#include <cstdlib>

#include "core/document.h"
#include "core/generator.h"
#include "core/observer.h"
#include "core/page.h"
#include "settings_core.h"

#ifndef OKULAR_PLUGIN_PREFIX
#error "define OKULAR_PLUGIN_PREFIX (directory that contains okular_generators/)"
#endif

namespace
{
class NullObserver : public Okular::DocumentObserver
{
};

void out(const char *key, const QString &value)
{
    std::printf("%s=%s\n", key, value.toUtf8().constData());
}
}

int main(int argc, char **argv)
{
    if (argc != 3 && argc != 5) {
        std::fprintf(stderr, "usage: kat_okular <mime> <file> [<x%%> <y%%>]\n");
        return 2;
    }
    QTemporaryDir scratch;
    qputenv("XDG_DATA_HOME", QByteArray((scratch.path() + QStringLiteral("/data")).toUtf8()));
    qputenv("XDG_CONFIG_HOME", QByteArray((scratch.path() + QStringLiteral("/config")).toUtf8()));
    qputenv("XDG_CACHE_HOME", QByteArray((scratch.path() + QStringLiteral("/cache")).toUtf8()));
    qputenv("QT_QPA_PLATFORM", "offscreen");
    qputenv("LC_ALL", "C.UTF-8");
    QApplication app(argc, argv);
    Okular::SettingsCore::instance(QStringLiteral("okular-kat"));
    QCoreApplication::addLibraryPath(QStringLiteral(OKULAR_PLUGIN_PREFIX));

    const QString path = QFileInfo(QString::fromLocal8Bit(argv[2])).absoluteFilePath();
    Okular::Document doc(nullptr);
    NullObserver observer;
    doc.addObserver(&observer);
    const QMimeType mime = QMimeDatabase().mimeTypeForName(QString::fromLatin1(argv[1]));
    if (doc.openDocument(path, QUrl::fromLocalFile(path), mime) != Okular::Document::OpenSuccess) {
        std::printf("open=failed\n");
        return 1;
    }
    std::printf("open=ok\n");
    out("generator", doc.generatorInfo().pluginId());
    std::printf("pages=%u\n", doc.pages());
    out("title", doc.documentInfo().get(Okular::DocumentInfo::Title));

    const Okular::Page *page = doc.page(0);
    std::printf("size0=%.0fx%.0f\n", page->width(), page->height());

    doc.requestTextPage(0);
    out("text0", page->text().simplified().left(48));

    const int w = 100;
    const int h = std::max(1, int(page->ratio() * w));
    doc.requestPixmaps({new Okular::PixmapRequest(&observer, 0, w, h, 1.0, 1, Okular::PixmapRequest::NoFeature)});
    if (const QPixmap *pm = page->getPixmap(&observer)) {
        const QImage img = pm->toImage().convertToFormat(QImage::Format_RGB32);
        std::printf("pix=%dx%d\n", img.width(), img.height());
        const int xp = argc == 5 ? std::atoi(argv[3]) : 50;
        const int yp = argc == 5 ? std::atoi(argv[4]) : 50;
        std::printf("px=%06x\n", img.pixel(img.width() * xp / 100, img.height() * yp / 100) & 0xffffff);
        std::printf("px_corner=%06x\n", img.pixel(1, 1) & 0xffffff);
    } else {
        std::printf("pix=none\n");
    }
    doc.closeDocument();
    doc.removeObserver(&observer);
    return 0;
}

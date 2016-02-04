package Dancer::Plugin::ImageWork;
# ABSTRACT: low-level image work

use strict;
use warnings;

use Dancer ':syntax';
use Dancer::Plugin;
use Dancer::Plugin::DBIC;
use Dancer::Plugin::FlashNote;

use Try::Tiny;
use Data::Dump qw(dump);
use FindBin qw($Bin);
use POSIX 'strftime';

use Image::Magick;
use Digest::MD5 qw(md5_hex);
use File::Copy qw(copy);
use File::Basename qw(fileparse);

=head1 Общие процедуры

Процедуры, которые управляют изображениями решено вынести в отдельный модуль
для упрощения логики.

=cut

=head2 img_fileparse

Процедура корректно разделяет полный путь к файлу на путь, файл и расширение.

Считается, что расширение файла не может быть меньше двух и больше четырёх
символов (7z, docx, jpeg - граничные случаи). В основной же своей массе
расширение имеет длину 3 символа (jpg, png, doc, odt, ...). Если расширение не
удовлетворяет этим условием, то оно считается неизвестным - добавляется суффикс
".unk". Интерпретация таких файлов - на совести других модулей сайта. 

На выходе - массив (путь, файл, расширение).

=cut

sub img_fileparse {
    my $filename = shift || "";

    my ( $path, $file, $ext );

    ( $file, $path ) = fileparse($filename);
    $file   =~ /(.*)\.(\w{2,4})$/; 
    $file   = lc($1) || "";
    $ext    = lc($2) || "unk";

    return ( $path, $file, $ext );
}

=head2 img_resize_list

Сформировать перечень ресайзов. Как минимум три являются стандартными:
- noresize - для сохранения оригинала, файл копируется "как есть";
- small    - для встраивания в страничку;
- thumb    - для создания галереи превьюшек;

На входе следует указать название галереи, в которую происходит загрузка
изображения. Если такая галерея определена в настройках модуля, то
в список будет включён дополнительный ресайз для указанных размеров;

В настройках модуля может быть указан свой размер превьюшек на случай, если
дизайн подразумевает другой (не 100 на 100 точек) размер превьюшек.

Дефолтный размер ресайза 800х600 точек, если иное не задано параметром default
в секции настроек плагина gallery (plugins->gallery->default: ...).

=cut

sub img_resize_list {
    my $galtype  = shift;
    my $defaultresize
                 = config->{plugins}->{gallery}->{"default"}
                    || "800x600";
    my $smallresize
                 = config->{plugins}->{gallery}->{"small"}
                    || "400x300";
    my $resizeto = config->{plugins}->{gallery}->{$galtype} 
                    || $defaultresize;
    my $thumb    = config->{plugins}->{gallery}->{"thumbnail"}
                    || "100x100";
    
    return { 
            "orig"      => "noresize", 
            $galtype    => $resizeto, 
            "small"     => $smallresize,
            "thumb"     => $thumb,
        };
}

=head2 destination folder

Получить абсолютный путь к папке, в которую складываются рисунки. Считается,
что права папки позволяют создавать в ней подпапки. Если требуемой подпапки
не существует, будет произведена попытка её создания.

=cut

sub img_destination_folder {
    my $galtype = shift;
    my $abspath = $Bin . "/../public/images/galleries/$galtype/";
    if ( ! -e $abspath ) { mkdir $abspath };
    
    return $abspath
}

=head2 img_relative_folder

Абсолютный путь к папке допустим только пока происходит работа с файлами. При
записи рисунка в БД требуется относительный путь.

=cut

sub img_relative_folder {
    my $galtype = shift;
    my $relpath = "/images/galleries/$galtype/";
    
    return $relpath
}

=head2 img_resize_by_rules

Принцип работы с изображением таков:

- сторонней процедурой на сервер загружается изображение;

- этой же процедурой ссылка на изображение прописывается в БД;

- формируется список правил преобразования изображения;

- вызывается эта процедура, которая по заданному списку правил выполняет ресайз
изображений

В качестве параметров на входе процедура принимает следующие параметры:

- ссылка (путь) к файлу-оригиналу;

- тип (название) галереи, к которой будет относиться этот файл;

- список правил преобразования для указанной галереи.

Если список правил не будет задан, то процедура вычислит его для указанной на
входе галереи.

Если галерея не будет указана явно, то процедура использует общую галерею с
именем "common".

Если изображение не считается графическим, то всегда будет создан только
оригинальный файл (без графической обработки).

=cut

sub img_resize_by_rules {
    my $sourcefile  = shift;
    my $galtype     = shift || "common";
    my $rules       = shift || img_resize_list($galtype);

    my $dstpath     = img_destination_folder($galtype);
    my ( $path, $file, $ext )
                    = img_fileparse($sourcefile);
    my ($val, $destfile);
    
    if ( ! -e $sourcefile ) { 
        warning " ============== $sourcefile is absend";
        return "";
    }
    
    my $image;
    foreach my $note ( keys(%{$rules}) ) {
        $val = $rules->{$note};
        $destfile = ${dstpath} . ${file} . "_" . $note . "." . $ext;
        if ($note =~ /^orig$/i) {
            copy ($sourcefile,  $destfile);
        } else {
            if ( $ext =~ /^(jpg|jpeg|png|bmp|ico)$/i ) {
                $image = Image::Magick->new;
                $image->Read($sourcefile);
                $image->Resize(geometry => $val);
                $image->Write($destfile);
                undef $image;
            } else {
                warning " =============== a file $destfile is not an image ";
            }
        }
    }

    return (img_relative_folder($galtype), $file, $ext);
}

=head2 img_convert_name 

Преобразует имя файла, добавляя после имени суффикс типа файла. 

Если изображение не считается графическим, то всегда будет возвращена ссылка на
оригинальный файл.

=cut

sub img_convert_name {
    my $filename = shift || "";
    my $suffix   = shift || "thumb";
    
    if ( $filename eq "" ) { return "" };
    my ( $path, $file, $ext ) = img_fileparse( $filename );
    if ( $ext !~ /^(jpg|jpeg|png|bmp|ico)$/i ) { $suffix = "orig"; }
    
    return "$path${file}_${suffix}.$ext";
}

hook 'before_template_render' => sub {
    my ($values) = @_;
    $values->{img_convert_name} = \&img_convert_name;
};

register img_fileparse          => \&img_fileparse;
register img_resize_by_rules    => \&img_resize_by_rules;
register img_resize_list        => \&img_resize_list;
register img_destination_folder => \&img_destination_folder;
register img_relative_folder    => \&img_relative_folder;

register img_convert_name       => \&img_convert_name;

register_plugin;

1;

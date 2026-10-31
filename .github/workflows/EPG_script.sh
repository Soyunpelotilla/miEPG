                                                      substr($stop_time_str, 4, 2) . "-" .
   #!/bin/bash
# ============================================================================== 
# Script: miEPG.sh 
# Versión: 3.6 - FIX autodetección Gracenote por contenido (cualquier dominio)
# ============================================================================== 

sed -i '/^ *$/d' epgs.txt
sed -i '/^ *$/d' canales.txt
rm -f EPG_temp* canales_epg*.txt
epg_count=0

echo "─── DESCARGANDO EPGs ───"

while IFS=, read -r epg; do
        ((epg_count++))
    extension="${epg##*.}"
    echo " │ Descargando: $epg"

    python3 - << PYEOF
import requests, re, os, gzip, shutil
from datetime import datetime, timedelta
url="$epg"
ext="$extension"
wanted=set()
try:
    with open("canales.txt","r",encoding="utf-8",errors="ignore") as f:
        for l in f:
            l=l.strip()
            if l: wanted.add(l.split(",")[0].strip())
except: pass

def fix(t):
    if not t: return t
    if "Ã" in t:
        try:
            for _ in range(2): t=t.encode('latin1').decode('utf-8')
        except: pass
    return t

try:
    r=requests.get(url, headers={"User-Agent":"Mozilla/5.0"}, stream=True, timeout=120)
    r.raise_for_status()
    # Peek primeros 20KB para detectar formato
    first_chunk=b""
    for chunk in r.iter_content(chunk_size=8192):
        first_chunk+=chunk
        if len(first_chunk)>20480: break
    text_peek=first_chunk.decode('utf-8',errors='ignore')

    is_gracenote=False
    if "programSeriesId" in text_peek or "tmsId" in text_peek:
        is_gracenote=True
    elif "<programme" not in text_peek and re.search(r'\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}', text_peek):
        is_gracenote=True

    if is_gracenote:
        print(f" └─► Autodetectado Gracenote por contenido (no por dominio), filtrando solo {wanted}")
        # Ya consumimos parte, reconstruir iterando desde el inicio
        # Re-hacer request para streaming limpio
        r2=requests.get(url, headers={"User-Agent":"Mozilla/5.0"}, stream=True, timeout=120)
        r2.raise_for_status()
        open("EPG_temp00.xml","w",encoding="utf-8").write('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n')
        cnt=0
        for line in r2.iter_lines(decode_unicode=True):
            if not line: continue
            m=re.search(r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(.+)', line)
            if not m: continue
            fecha,hora,resto=m.groups()
            titulo=fix(resto.split("  ")[0][:120].strip())
            if len(titulo)<3: continue
            cid_match=re.search(r'\b(\d{4,6})\b', line)
            cid=cid_match.group(1) if cid_match else ""
            if wanted and cid and cid not in wanted: continue
            try:
                dt=datetime.strptime(f"{fecha} {hora}", "%Y-%m-%d %H:%M:%S")
                s=dt.strftime("%Y%m%d%H%M%S")+" +0000"
                e=(dt+timedelta(minutes=60)).strftime("%Y%m%d%H%M%S")+" +0000"
                with open("EPG_temp00.xml","a",encoding="utf-8") as out:
                    out.write(f'<programme start="{s}" stop="{e}" channel="{cid}"><title lang="es">{titulo}</title></programme>\n')
                cnt+=1
            except: continue
        open("EPG_temp00.xml","a",encoding="utf-8").write('</tv>\n')
        print(f"   OK {cnt} programas Gracenote filtrados (sin bajar 150MB enteros)")
    else:
        print(f" └─► XMLTV normal detectado, bajando completo")
        # Guardar lo que ya tenemos + resto
        target="EPG_temp00.xml.gz" if ext=="gz" else "EPG_temp00.xml"
        with open(target,"wb") as f:
            f.write(first_chunk)
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
        if ext=="gz":
            try:
                with gzip.open(target,'rb') as gz:
                    with open("EPG_temp00.xml",'wb') as out:
                        shutil.copyfileobj(gz,out)
                os.remove(target)
            except:
                # No era gz real
                os.rename(target,"EPG_temp00.xml")
        print("   OK bajado")
except Exception as ex:
    print(f" ❌ ERROR descarga: {ex}")
    open("EPG_temp00.xml","w").write("")
PYEOF

        if [ ! -s EPG_temp00.xml ]; then
            echo " └─► ❌ ERROR: El archivo descargado está vacío o no se descargó correctamente"
            continue
        fi

        if [ -f EPG_temp00.xml ]; then

        # ====== FIX GRACENOTE: Detectar si es formato (no XMLTV) - por contenido ======
        if ! grep -q "<programme" EPG_temp00.xml && grep -q "programSeriesId\|tmsId\|^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:" EPG_temp00.xml; then
            echo " └─► Detectado formato Gracenote por contenido, convirtiendo a XMLTV..."
            python3 - << 'PYEOF'
import re, xml.etree.ElementTree as ET
from xml.dom import minidom
from datetime import datetime, timedelta

def arreglar_acentos(texto):
    if not texto: return texto
    try:
        if "Ã" in texto or "Â" in texto:
            for _ in range(2):
                try:
                    texto = texto.encode('latin1').decode('utf-8')
                except:
                    break
    except:
        pass
    return texto

with open("EPG_temp00.xml","r",encoding="utf-8",errors="ignore") as f:
    raw=f.read()

tv=ET.Element("tv")
canales={}
for line in raw.splitlines()[:5000]:
    m=re.search(r'(\d{4,6})\s+\d{4,6}\s*$', line)
    if m:
        cid=m.group(1)
        nombre=arreglar_acentos(line[:m.start()].strip())
        if nombre and cid not in canales:
            canales[cid]=nombre
            ch=ET.SubElement(tv,"channel")
            ch.set("id",cid)
            ET.SubElement(ch,"display-name").text=nombre

prog_pat=re.compile(r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(.+?)(?:https://|$)')
count=0
for line in raw.splitlines():
    m=prog_pat.search(line)
    if not m: continue
    fecha,hora,resto=m.groups()
    titulo=arreglar_acentos(resto.split("  ")[0][:120].strip())
    if len(titulo)<3: continue
    try:
        dt=datetime.strptime(f"{fecha} {hora}", "%Y-%m-%d %H:%M:%S")
        start=dt.strftime("%Y%m%d%H%M%S")+" +0000"
        stop=(dt+timedelta(minutes=60)).strftime("%Y%m%d%H%M%S")+" +0000"
        cid_match=re.search(r'\b(\d{4,6})\b', line[:100])
        cid=cid_match.group(1) if cid_match and cid_match.group(1) in canales else "62161"
        if cid not in canales:
            canales[cid]="FOX MX"
            ch=ET.SubElement(tv,"channel")
            ch.set("id",cid)
            ET.SubElement(ch,"display-name").text="FOX MX"
        pr=ET.SubElement(tv,"programme")
        pr.set("start",start)
        pr.set("stop",stop)
        pr.set("channel",cid)
        t=ET.SubElement(pr,"title")
        t.set("lang","es")
        t.text=titulo
        count+=1
    except:
        continue

xml_str=ET.tostring(tv,encoding="unicode")
pretty=minidom.parseString(xml_str).toprettyxml(indent="  ",encoding="UTF-8").decode("UTF-8")
open("EPG_temp00.xml","w",encoding="utf-8").write(pretty)
print(f"   Convertidos {count} programas Gracenote -> XMLTV con acentos arreglados")
PYEOF
        fi
        # ====== FIN FIX GRACENOTE ======

        listado="canales_epg${epg_count}.txt"
        echo " └─► Generando listado de canales: $listado"
        echo "# Fuente: $epg" > "$listado"
                awk '
                /<channel / {
                    match($0, /id="([^"]+)"/, a); id=a[1]; name=""; logo="";
                }
                /<display-name[^>]*>/ && name == "" {
                    match($0, /<display-name[^>]*>([^<]+)<\/display-name>/, a);
                    name=a[1];
                }
                /<icon src/ {
                    match($0, /src="([^"]+)"/, a); logo=a[1];
                }
                /<\/channel>/ {
                    print id "," name "," logo;
                }
                ' EPG_temp00.xml >> "$listado"
                cat EPG_temp00.xml >> EPG_temp.xml
        sed -i 's/></>\n</g' EPG_temp.xml               
    fi  
done < epgs.txt

echo "─── PROCESANDO CANALES ───"

mapfile -t canales < canales.txt
for i in "${!canales[@]}"; do
    IFS=',' read -r old new logo offset <<< "${canales[$i]}"
    if [[ "$logo" =~ ^[+-]?[0-9]+$ ]] && [[ -z "$offset" ]]; then
        offset="$logo"
        logo=""
    fi
    new="${new:-}"
    logo="${logo:-}"
    offset="${offset:-}"
    canales[$i]="$old,$new,$logo,$offset"
done

etiquetas_sed=""
if [ -f variables.txt ]; then
    sufijos=$(grep "display-name=" variables.txt | cut -d'=' -f2 | sed 's/, /,/g')
    IFS=',' read -r -a array_etiquetas <<< "$sufijos"
    linea_ins=3
    for etiq in "${array_etiquetas[@]}"; do
        etiq_clean=$(echo "$etiq" | xargs)
        if [ -n "$etiq_clean" ]; then
            etiquetas_sed="${etiquetas_sed}${linea_ins}i\  <display-name>${new} ${etiq_clean}</display-name>\n"
            ((linea_ins++))
        fi
    done
fi

for linea in "${canales[@]}"; do
    IFS=',' read -r old new logo offset <<< "$linea"
    contar_channel="$(grep -c "channel=\"$old\"" EPG_temp.xml)"
        if [ "${contar_channel:-0}" -gt 0 ]; then
        
        logo_original=$(sed -n "/<channel id=\"${old}\">/,/<\/channel>/p" EPG_temp.xml | grep "<icon src" | head -1 | sed 's/^[[:space:]]*//')
        logo_final=""
        if [ -n "$logo" ]; then
            logo_final="    <icon src=\"${logo}\" />"
        else
            logo_final="    $logo_original"
        fi
        echo "  <channel id=\"${new}\">" > EPG_temp01.xml
        if [ -f variables.txt ]; then
            sufijos=$(grep "display-name=" variables.txt | cut -d'=' -f2 | sed 's/, /,/g')
            IFS=',' read -r -a array_etiquetas <<< "$sufijos"
            for etiq in "${array_etiquetas[@]}"; do
                etiq_clean=$(echo "$etiq" | xargs)
                if [ -n "$etiq_clean" ]; then
                    echo "    <display-name>${new} ${etiq_clean}</display-name>" >> EPG_temp01.xml
                fi
            done
        else
            echo "    <display-name>${new}</display-name>" >> EPG_temp01.xml
        fi
        [ -n "$logo_final" ] && echo "$logo_final" >> EPG_temp01.xml
        echo '  </channel>' >> EPG_temp01.xml
        cat EPG_temp01.xml >> EPG_temp1.xml
        sed -i '$!N;/^\(.*\)\n\1$/!P;D' EPG_temp1.xml
        sed -n "/<programme.*\"${old}\"/,/<\/programme>/p" EPG_temp.xml > EPG_temp02.xml
        sed -i '/<programme/s/\">.*/\"/g' EPG_temp02.xml
        sed -i "s# channel=\"${old}\"##g" EPG_temp02.xml
        sed -i "/<programme/a EPG_temp channel=\"${new}\">" EPG_temp02.xml
        sed -i ':a;N;$!ba;s/\nEPG_temp//g' EPG_temp02.xml
  
                if [[ "$offset" =~ ^[+-]?[0-9]+$ ]]; then
                        export OFFSET="$offset"
                        export NEW_CHANNEL="$new"
                        perl -MDate::Parse -MDate::Format -i'' -pe '
                        BEGIN {
                                $offset_sec = $ENV{OFFSET} * 3600;
                                $new_channel_name = $ENV{NEW_CHANNEL};
                        }
                        if (/<programme start="([^"]+) (\+?\d+)" stop="([^"]+) (\+?\d+)" channel="[^"]+">/) {
                                my ($start_time_str, $start_tz, $stop_time_str, $stop_tz) = ($1, $2, $3, $4);
                                my $start_fmt = substr($start_time_str, 0, 4) . "-" . substr($start_time_str, 4, 2) . "-" . substr($start_time_str, 6, 2) . " " . substr($start_time_str, 8, 2) . ":" . substr($start_time_str, 10, 2) . ":" . substr($start_time_str, 12, 2);
                                my $stop_fmt = substr($stop_time_str, 0, 4) . "-" . substr($stop_time_str, 4, 2) . "-" . substr($stop_time_str, 6, 2) . " " . substr($stop_time_str, 8, 2) . ":" . substr($stop_time_str, 10, 2) . ":" . substr($stop_time_str, 12, 2);
                                my $start = str2time("$start_fmt $start_tz") + $offset_sec;
                                my $stop = str2time("$stop_fmt $stop_tz") + $offset_sec;
                                my $start_formatted = time2str("%Y%m%d%H%M%S $start_tz", $start);
                                my $stop_formatted = time2str("%Y%m%d%H%M%S $stop_tz", $stop);
                                s/<programme start="[^"]+" stop="[^"]+" channel="[^"]+">/<programme start="$start_formatted" stop="$stop_formatted" channel="$new_channel_name">/;
                        }
                        ' EPG_temp02.xml
                fi
  
        cat EPG_temp02.xml >> EPG_temp2.xml
  
    else
        echo "        Saltando canal: $old ··· $contar_channel coincidencias"
    fi
done

echo "─── PROCESANDO LIMITES TEMPORALES Y ACUMULACIÓN ───"
if [ -f epg_acumulado.xml ]; then
    echo " Rescatando programas de epg_acumulado.xml..."
    sed -n '/<programme/,/<\/programme>/p' epg_acumulado.xml >> EPG_temp2.xml
fi
dias_pasados=$(grep "dias-pasados=" variables.txt | cut -d'=' -f2 | xargs)
dias_pasados=${dias_pasados:-0}
dias_futuros=$(grep "dias-futuros=" variables.txt | cut -d'=' -f2 | xargs)
dias_futuros=${dias_futuros:-99}
fecha_corte_pasado=$(date -d "$dias_pasados days ago 00:00" +"%Y%m%d%H%M%S")
fecha_corte_futuro=$(date -d "$dias_futuros days 02:00" +"%Y%m%d%H%M%S")
echo " Limpieza Pasado: Manteniendo desde $fecha_corte_pasado ($dias_pasados días)"
echo " Limpieza Futuro: Limitando hasta $fecha_corte_futuro ($dias_futuros días)"
perl -i -ne '
    BEGIN { $c_old = "'$fecha_corte_pasado'"; $c_new = "'$fecha_corte_futuro'"; %visto=(); $pasados=0; $futuros=0; $duplicados=0; $aceptados=0; }
    if (/<programme start="(\d{14})[^"]+" stop="[^"]+" channel="([^"]+)">/) {
        $inicio = $1; $canal = $2; $llave = "$inicio-$canal";
        if ($inicio < $c_old) { $pasados++; $imprimir = 0; }
        elsif ($inicio > $c_new) { $futuros++; $imprimir = 0; }
        elsif ($visto{$llave}++) { $duplicados++; $imprimir = 0; }
        else { $aceptados++; $imprimir = 1; }
    }
    print if $imprimir;
    if (/<\/programme>/) { $imprimir = 0; }
    END { print STDERR " ─► Añadidos/Mantenidos: $aceptados\n"; print STDERR " ─►️ Pasados eliminados: $pasados\n"; print STDERR " ─►️ Futuros eliminados: $futuros\n"; print STDERR " ─►️ Duplicados eliminados: $duplicados\n"; }
' EPG_temp2.xml

date_stamp=$(date +"%d/%m/%Y %R")
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<tv generator-info-name=\"miEPG v3.6\" generator-info-url=\"https://github.com/davidmuma/miEPG\">"
    [ -f EPG_temp1.xml ] && cat EPG_temp1.xml
    [ -f EPG_temp2.xml ] && cat EPG_temp2.xml
    echo '</tv>'
} > miEPG.xml

echo "─── VALIDACION FINAL DEL XML ───"
error_log=$(xmllint --noout miEPG.xml 2>&1)
if [ $? -eq 0 ]; then
    echo " │ El archivo XML está perfectamente formado."
    num_canales=$(grep -c "<channel " miEPG.xml)
    num_programas=$(grep -c "<programme " miEPG.xml)
    echo " └─► Canales: $num_canales | Programas: $num_programas"
    cp miEPG.xml epg_acumulado.xml
else
    echo " ❌ ERROR: $error_log"
fi
rm -f EPG_temp* 2>/dev/null
echo "─── PROCESO FINALIZADO ───"                                                                        substr($stop_time_str, 6, 2) . " " .
                                                                           substr($stop_time_str, 8, 2) . ":" .
                                                                           substr($stop_time_str, 10, 2) . ":" .
                                                                           substr($stop_time_str, 12, 2);

                                my $start = str2time("$start_fmt $start_tz") + $offset_sec;
                                my $stop = str2time("$stop_fmt $stop_tz") + $offset_sec;

                                my $start_formatted = time2str("%Y%m%d%H%M%S $start_tz", $start);
                                my $stop_formatted = time2str("%Y%m%d%H%M%S $stop_tz", $stop);

                                s/<programme start="[^"]+" stop="[^"]+" channel="[^"]+">/<programme start="$start_formatted" stop="$stop_formatted" channel="$new_channel_name">/;
                        }
                        ' EPG_temp02.xml
                fi
  
        cat EPG_temp02.xml >> EPG_temp2.xml
  
    else
        echo "        Saltando canal: $old ··· $contar_channel coincidencias"
    fi
done

echo "─── PROCESANDO LIMITES TEMPORALES Y ACUMULACIÓN ───"

# 1. Asegurarnos de que EPG_temp2.xml existe (donde se han ido metiendo los programas nuevos) y añadir el histórico de epg_acumulado.xml a ese mismo archivo.
if [ -f epg_acumulado.xml ]; then
    echo " Rescatando programas de epg_acumulado.xml..."
    sed -n '/<programme/,/<\/programme>/p' epg_acumulado.xml >> EPG_temp2.xml
fi

# 2. Leer variables de días desde variables.txt
dias_pasados=$(grep "dias-pasados=" variables.txt | cut -d'=' -f2 | xargs)
dias_pasados=${dias_pasados:-0}

dias_futuros=$(grep "dias-futuros=" variables.txt | cut -d'=' -f2 | xargs)
dias_futuros=${dias_futuros:-99}

# 3. Calcular fechas de corte (Formato XMLTV)
fecha_corte_pasado=$(date -d "$dias_pasados days ago 00:00" +"%Y%m%d%H%M%S")
fecha_corte_futuro=$(date -d "$dias_futuros days 02:00" +"%Y%m%d%H%M%S")

echo " Limpieza Pasado: Manteniendo desde $fecha_corte_pasado ($dias_pasados días)"
echo " Limpieza Futuro: Limitando hasta $fecha_corte_futuro ($dias_futuros días)"

# 4. Filtro Perl Avanzado: Deduplicación + Reporte Desglosado
perl -i -ne '
    BEGIN { 
        $c_old = "'$fecha_corte_pasado'"; 
        $c_new = "'$fecha_corte_futuro'"; 
        %visto=(); 
        $pasados=0; $futuros=0; $duplicados=0; $aceptados=0;
    }
    if (/<programme start="(\d{14})[^"]+" stop="[^"]+" channel="([^"]+)">/) {
        $inicio = $1; $canal = $2;
        $llave = "$inicio-$canal"; 
        if ($inicio < $c_old) { $pasados++; $imprimir = 0; }
        elsif ($inicio > $c_new) { $futuros++; $imprimir = 0; }
        elsif ($visto{$llave}++) { $duplicados++; $imprimir = 0; }
        else { $aceptados++; $imprimir = 1; }
    }
    print if $imprimir;
    if (/<\/programme>/) { $imprimir = 0; }
    END { 
        print STDERR " ─► Añadidos/Mantenidos: $aceptados\n";
        print STDERR " ─►️ Pasados eliminados: $pasados\n";
        print STDERR " ─►️ Futuros eliminados: $futuros\n";
        print STDERR " ─►️ Duplicados eliminados: $duplicados\n";
    }
' EPG_temp2.xml

date_stamp=$(date +"%d/%m/%Y %R")
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<tv generator-info-name=\"miEPG v3.6\" generator-info-url=\"https://github.com/davidmuma/miEPG\">"
    
    # Insertar los canales (con sus variantes y logos que procesamos antes)
    [ -f EPG_temp1.xml ] && cat EPG_temp1.xml
    
    # Insertar los programas (nuevos + antiguos filtrados)
    [ -f EPG_temp2.xml ] && cat EPG_temp2.xml
    
    echo '</tv>'
} > miEPG.xml

echo "─── VALIDACION FINAL DEL XML ───"

# Ejecutamos xmllint capturando todos los errores
# 2>&1 redirige los errores al flujo estándar para poder guardarlos en la variable
error_log=$(xmllint --noout miEPG.xml 2>&1)

if [ $? -eq 0 ]; then
    echo " │ El archivo XML está perfectamente formado."
    
    num_canales=$(grep -c "<channel " miEPG.xml)
    num_programas=$(grep -c "<programme " miEPG.xml)
    echo " └─► Canales: $num_canales | Programas: $num_programas"

    cp miEPG.xml epg_acumulado.xml
    echo " epg_acumulado.xml actualizado para la próxima sesión."
else
    echo " ❌ ERROR: Se han detectado fallos en la estructura del XML."
    echo "──────────────────────────────────────────────────────────────────"
    
    # Extraemos todos los números de línea únicos que reporta xmllint
    lineas_con_error=$(echo "$error_log" | grep -oP '(?<=miEPG.xml:)\d+' | sort -nu)

    echo "Resumen de líneas con errores:"
    for linea in $lineas_con_error; do
        # Buscamos el mensaje específico de xmllint para esa línea
        detalle=$(echo "$error_log" | grep "miEPG.xml:$linea:" | head -1 | cut -d':' -f3-)
        
        echo "📍 Línea $linea:"
        echo "   Error: $detalle"
        # Mostramos el contenido real de esa línea en el archivo
        contenido_linea=$(sed -n "${linea}p" miEPG.xml | xargs)
        echo "   Texto: \"$contenido_linea\""
        echo "───"
    done
    
    echo "──────────────────────────────────────────────────────────────────"
    echo " ⚠️ ADVERTENCIA: epg_acumulado.xml NO se ha actualizado."
fi

# Limpieza de archivos temporales de la sesión
rm -f EPG_temp* 2>/dev/null
echo "─── PROCESO FINALIZADO ───"

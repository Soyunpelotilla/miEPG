#!/bin/bash
# ============================================================================== 
# Script: miEPG.sh 
# Versión: 3.6 - MOD con User-Agent PC + anti-duplicados por solapamiento FIX
# ============================================================================== 

sed -i '/^ *$/d' epgs.txt
sed -i '/^ *$/d' canales.txt
rm -f EPG_temp* canales_epg*.txt

epg_count=0
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

echo "─── DESCARGANDO EPGs ───"
while IFS=, read -r epg; do
	((epg_count++))
    extension="${epg##*.}"
    if [ "$extension" = "gz" ]; then
        echo " │ Descargando y descomprimiendo: $epg"
        wget --header="User-Agent: $UA" -O EPG_temp00.xml.gz -q "$epg"
        if [ ! -s EPG_temp00.xml.gz ]; then echo " └─► ❌ ERROR vacío"; continue; fi
        if ! gzip -t EPG_temp00.xml.gz 2>/dev/null; then echo " └─► ❌ ERROR no gzip"; continue; fi
        gzip -d -f EPG_temp00.xml.gz
    else
        echo " │ Descargando: $epg"
        wget --header="User-Agent: $UA" -O EPG_temp00.xml -q "$epg"
        if [ ! -s EPG_temp00.xml ]; then echo " └─► ❌ ERROR vacío"; continue; fi
    fi
	if [ -f EPG_temp00.xml ]; then
        listado="canales_epg${epg_count}.txt"
        echo " └─► Generando listado de canales: $listado"
        echo "# Fuente: $epg" > "$listado"
		awk '
		/<channel / { match($0, /id="([^"]+)"/, a); id=a[1]; name=""; logo=""; }
		/<display-name[^>]*>/ && name == "" { match($0, /<display-name[^>]*>([^<]+)<\/display-name>/, a); name=a[1]; }
		/<icon src/ { match($0, /src="([^"]+)"/, a); logo=a[1]; }
		/<\/channel>/ { print id "," name "," logo; }
		' EPG_temp00.xml >> "$listado"
		cat EPG_temp00.xml >> EPG_temp.xml
        sed -i 's/></>\n</g' EPG_temp.xml		
    fi	
done < epgs.txt

echo "─── PROCESANDO CANALES ───"
mapfile -t canales < canales.txt
for i in "${!canales[@]}"; do
    IFS=',' read -r old new logo offset <<< "${canales[$i]}"
    if [[ "$logo" =~ ^[+-]?[0-9]+$ ]] && [[ -z "$offset" ]]; then offset="$logo"; logo=""; fi
    canales[$i]="$old,$new,$logo,$offset"
done

for linea in "${canales[@]}"; do
    IFS=',' read -r old new logo offset <<< "$linea"
    contar_channel="$(grep -c "channel=\"$old\"" EPG_temp.xml)"
	if [ "${contar_channel:-0}" -gt 0 ]; then
        logo_original=$(sed -n "/<channel id=\"${old}\">/,/<\/channel>/p" EPG_temp.xml | grep "<icon src" | head -1 | sed 's/^[[:space:]]*//')
        logo_final=""; [ -n "$logo" ] && logo_final="    <icon src=\"${logo}\" />" || logo_final="    $logo_original"
        echo "  <channel id=\"${new}\">" > EPG_temp01.xml
        if [ -f variables.txt ]; then
            sufijos=$(grep "display-name=" variables.txt | cut -d'=' -f2 | sed 's/, /,/g')
            IFS=',' read -r -a array_etiquetas <<< "$sufijos"
            for etiq in "${array_etiquetas[@]}"; do etiq_clean=$(echo "$etiq" | xargs); [ -n "$etiq_clean" ] && echo "    <display-name>${new} ${etiq_clean}</display-name>" >> EPG_temp01.xml; done
        else
            echo "    <display-name>${new}</display-name>" >> EPG_temp01.xml
        fi
        [ -n "$logo_final" ] && echo "$logo_final" >> EPG_temp01.xml
        echo '  </channel>' >> EPG_temp01.xml
        echo " │ $old -> $new ··· $contar_channel"
        cat EPG_temp01.xml >> EPG_temp1.xml
        sed -i '$!N;/^\(.*\)\n\1$/!P;D' EPG_temp1.xml
        sed -n "/<programme.*\"${old}\"/,/<\/programme>/p" EPG_temp.xml > EPG_temp02.xml
        sed -i '/<programme/s/\">.*/\"/g' EPG_temp02.xml
        sed -i "s# channel=\"${old}\"##g" EPG_temp02.xml
        sed -i "/<programme/a EPG_temp channel=\"${new}\">" EPG_temp02.xml
        sed -i ':a;N;$!ba;s/\nEPG_temp//g' EPG_temp02.xml
		if [[ "$offset" =~ ^[+-]?[0-9]+$ ]]; then
			echo " └─► Ajustando hora $new ($offset h)"
			export OFFSET="$offset"; export NEW_CHANNEL="$new"
			perl -MDate::Parse -MDate::Format -i'' -pe '
			BEGIN { $offset_sec = $ENV{OFFSET} * 3600; $new_channel_name = $ENV{NEW_CHANNEL}; }
			if (/<programme start="([^"]+) (\+?\d+)" stop="([^"]+) (\+?\d+)" channel="[^"]+">/) {
				my ($a,$b,$c,$d)=($1,$2,$3,$4);
				my $sf = substr($a,0,4)."-".substr($a,4,2)."-".substr($a,6,2)." ".substr($a,8,2).":".substr($a,10,2).":".substr($a,12,2);
				my $ef = substr($c,0,4)."-".substr($c,4,2)."-".substr($c,6,2)." ".substr($c,8,2).":".substr($c,10,2).":".substr($c,12,2);
				my $s = str2time("$sf $b") + $offset_sec; my $e = str2time("$ef $d") + $offset_sec;
				my $s2 = time2str("%Y%m%d%H%M%S $b", $s); my $e2 = time2str("%Y%m%d%H%M%S $d", $e);
				s/<programme start="[^"]+" stop="[^"]+" channel="[^"]+">/<programme start="$s2" stop="$e2" channel="$new_channel_name">/;
			}' EPG_temp02.xml
		fi
        cat EPG_temp02.xml >> EPG_temp2.xml
    else
        echo "        Saltando: $old"
    fi
done

echo "─── PROCESANDO LIMITES TEMPORALES Y ACUMULACIÓN (anti-solapamiento) ───"
[ -f epg_acumulado.xml ] && sed -n '/<programme/,/<\/programme>/p' epg_acumulado.xml >> EPG_temp2.xml

dias_pasados=$(grep "dias-pasados=" variables.txt | cut -d'=' -f2 | xargs); dias_pasados=${dias_pasados:-0}
dias_futuros=$(grep "dias-futuros=" variables.txt | cut -d'=' -f2 | xargs); dias_futuros=${dias_futuros:-99}
fecha_corte_pasado=$(date -d "$dias_pasados days ago 00:00" +"%Y%m%d%H%M%S")
fecha_corte_futuro=$(date -d "$dias_futuros days 02:00" +"%Y%m%d%H%M%S")
echo " Desde $fecha_corte_pasado hasta $fecha_corte_futuro"

perl -i -ne '
    BEGIN { 
        $c_old = "'$fecha_corte_pasado'"; 
        $c_new = "'$fecha_corte_futuro'"; 
        %visto_exact=(); %visto_titulo=(); %ultimo_fin=();
        $pasados=0; $futuros=0; $duplicados=0; $aceptados=0;
        $titulo_actual=""; $buffer=""; $inicio_actual=""; $fin_actual=""; $canal_actual=""; $imprimir=0;
    }
    if (/<programme start="(\d{14})[^"]+" stop="(\d{14})[^"]+" channel="([^"]+)">/) {
        $inicio_actual=$1; $fin_actual=$2; $canal_actual=$3;
        $titulo_actual=""; $buffer=""; $imprimir=0;
    }
    if (/<title[^>]*>([^<]+)<\/title>/ && $titulo_actual eq "") { $titulo_actual=$1; }
    $buffer .= $_;
    if (/<\/programme>/) {
        if ($titulo_actual ne "") {
            $clave_exact = $inicio_actual."-".$canal_actual;
            $clave_titulo = lc($canal_actual."-".$titulo_actual);
            if ($inicio_actual < $c_old) { $pasados++; $imprimir=0; }
            elsif ($inicio_actual > $c_new) { $futuros++; $imprimir=0; }
            elsif ($visto_exact{$clave_exact}) { $duplicados++; $imprimir=0; }
            elsif (exists $ultimo_fin{$canal_actual} && $inicio_actual < $ultimo_fin{$canal_actual} && $visto_titulo{$clave_titulo}) {
                $duplicados++; $imprimir=0;
            } else {
                $aceptados++; $visto_exact{$clave_exact}=1; $visto_titulo{$clave_titulo}=1; $ultimo_fin{$canal_actual}=$fin_actual; $imprimir=1;
            }
        }
        print $buffer if $imprimir;
        $buffer=""; $titulo_actual=""; next;
    }
    END { print STDERR " ─► Añadidos: $aceptados | Duplicados solapados: $duplicados | Pasados: $pasados | Futuros: $futuros\n"; }
' EPG_temp2.xml

{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<tv generator-info-name=\"miEPG v3.6 MOD FIX\" generator-info-url=\"https://github.com/davidmuma/miEPG\">"
    [ -f EPG_temp1.xml ] && cat EPG_temp1.xml
    [ -f EPG_temp2.xml ] && cat EPG_temp2.xml
    echo '</tv>'
} > miEPG.xml

echo "─── VALIDACION FINAL DEL XML ───"
error_log=$(xmllint --noout miEPG.xml 2>&1)
if [ $? -eq 0 ]; then
    echo " │ XML OK - Canales: $(grep -c "<channel " miEPG.xml) Programas: $(grep -c "<programme " miEPG.xml)"
    cp miEPG.xml epg_acumulado.xml
else
    echo " ❌ ERROR XML"; echo "$error_log" | head -20
fi
rm -f EPG_temp* 2>/dev/null
echo "─── PROCESO FINALIZADO ───"

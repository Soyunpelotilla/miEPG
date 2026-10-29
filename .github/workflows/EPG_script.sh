#!/bash
# ============================================================================== 
# Script: miEPG.sh 
# Versión: 3.6
# Función: Combina múltiples XMLs, renombra canales, cambia logos y ajusta hora 
# ============================================================================== 

sed -i '/^ *$/d' epgs.txt
sed -i '/^ *$/d' canales.txt

rm -f EPG_temp* canales_epg*.txt

epg_count=0

echo "─── DESCARGANDO EPGs ───"

while IFS=, read -r epg; do
	((epg_count++))
    extension="${epg##*.}"
    if [ "$extension" = "gz" ]; then
        echo " │ Descargando y descomprimiendo: $epg"
        wget -O EPG_temp00.xml.gz -q "$epg"
        if [ ! -s EPG_temp00.xml.gz ]; then
            echo " └─► ❌ ERROR: El archivo descargado está vacío o no se descargó correctamente"
            continue
        fi
        if ! gzip -t EPG_temp00.xml.gz 2>/dev/null; then
            echo " └─► ❌ ERROR: El archivo no es un gzip válido"
            continue
        fi
        gzip -d -f EPG_temp00.xml.gz
    else
        echo " │ Descargando: $epg"
        wget -O EPG_temp00.xml -q "$epg"
        if [ ! -s EPG_temp00.xml ]; then
            echo " └─► ❌ ERROR: El archivo descargado está vacío o no se descargó correctamente"
            continue
        fi
    fi
	if [ -f EPG_temp00.xml ]; then
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

# Leer etiquetas de variables.txt
etiquetas_sed=""
if [ -f variables.txt ]; then
    # Extrae lo que hay después de display-name=, quita espacios y separa por comas
    sufijos=$(grep "display-name=" variables.txt | cut -d'=' -f2 | sed 's/, /,/g')
    IFS=',' read -r -a array_etiquetas <<< "$sufijos"
    
    # Creamos una lista de comandos para sed (se insertarán en la línea 3 en adelante)
    linea_ins=3
    for etiq in "${array_etiquetas[@]}"; do
        etiq_clean=$(echo "$etiq" | xargs) # Limpia espacios
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
	
        # 1. Extraer el logo original por si no hay uno nuevo en canales.txt
        logo_original=$(sed -n "/<channel id=\"${old}\">/,/<\/channel>/p" EPG_temp.xml | grep "<icon src" | head -1 | sed 's/^[[:space:]]*//')
        
        # 2. Definir qué logo usar (el nuevo o el extraído)
        logo_final=""
        if [ -n "$logo" ]; then
            logo_final="    <icon src=\"${logo}\" />"
        else
            logo_final="    $logo_original"
        fi

        # 3. Construir el nuevo archivo de canal desde cero (EPG_temp01.xml)
        echo "  <channel id=\"${new}\">" > EPG_temp01.xml
        
        # 4. Insertar los nombres basados en variables.txt
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
            # Si no hay variables.txt, ponemos al menos el nombre base
            echo "    <display-name>${new}</display-name>" >> EPG_temp01.xml
        fi

        # 5. Insertar el logo al final
        [ -n "$logo_final" ] && echo "$logo_final" >> EPG_temp01.xml
        echo '  </channel>' >> EPG_temp01.xml

        # Logs informativos
        if [ -n "$logo" ]; then
            echo " │ Nombre EPG: $old · Nuevo nombre: $new · Cambiando logo ··· $contar_channel coincidencias"
        else
            echo " │ Nombre EPG: $old · Nuevo nombre: $new · Manteniendo logo ··· $contar_channel coincidencias"
        fi

        cat EPG_temp01.xml >> EPG_temp1.xml
        sed -i '$!N;/^\(.*\)\n\1$/!P;D' EPG_temp1.xml

        sed -n "/<programme.*\"${old}\"/,/<\/programme>/p" EPG_temp.xml > EPG_temp02.xml
        sed -i '/<programme/s/\">.*/\"/g' EPG_temp02.xml
        sed -i "s# channel=\"${old}\"##g" EPG_temp02.xml
        sed -i "/<programme/a EPG_temp channel=\"${new}\">" EPG_temp02.xml
        sed -i ':a;N;$!ba;s/\nEPG_temp//g' EPG_temp02.xml
  
		if [[ "$offset" =~ ^[+-]?[0-9]+$ ]]; then
			echo " └─► Ajustando hora en el canal $new ($offset horas)"
			export OFFSET="$offset"
			export NEW_CHANNEL="$new"
            
			perl -MDate::Parse -MDate::Format -i'' -pe '
			BEGIN {
				$offset_sec = $ENV{OFFSET} * 3600;
				$new_channel_name = $ENV{NEW_CHANNEL};
			}
			if (/<programme start="([^"]+) (\+?\d+)" stop="([^"]+) (\+?\d+)" channel="[^"]+">/) {
				my ($start_time_str, $start_tz, $stop_time_str, $stop_tz) = ($1, $2, $3, $4);

				my $start_fmt = substr($start_time_str, 0, 4) . "-" .
								substr($start_time_str, 4, 2) . "-" .
								substr($start_time_str, 6, 2) . " " .
								substr($start_time_str, 8, 2) . ":" .
								substr($start_time_str, 10, 2) . ":" .
								substr($start_time_str, 12, 2);

				my $stop_fmt = substr($stop_time_str, 0, 4) . "-" .
							   substr($stop_time_str, 4, 2) . "-" .
							   substr($stop_time_str, 6, 2) . " " .
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

# ==============================================================================
# BLOQUE AUTOMÁTICO: Ajuste de Zona Horaria para miEPG.xml
# Este bloque se ejecuta después de generar miEPG.xml.
# Lee los offsets de canales.txt y aplica las horas correctas (ej. +6 para México a España).
# Cambia la etiqueta +0000 por +0100 (Hora invierno en Cáceres/Extremadura).
# No depende de módulos Perl externos, usa awk.
# ==============================================================================

echo "=== Ajustando zona horaria en miEPG.xml ==="

while IFS=, read -r ch_id ch_name ch_logo ch_offset; do
    # Si el offset está vacío, pasamos al siguiente canal
    [ -z "$ch_offset" ] && continue
    
    # Limpiamos el offset de posibles espacios
    offset=$(echo "$ch_offset" | tr -d ' ')
    [ -z "$offset" ] && continue
    
    # Limpiamos el nombre del canal de espacios extra
    ch_name_clean=$(echo "$ch_name" | sed 's/^ *//;s/ *$//')
    
    echo "  -> Procesando: $ch_name_clean (Offset: $offset horas)"
    
    # Usamos awk para modificar el archivo XML
    # El patrón busca start="AÑOMMDDHHMMSS +ZZZZ" y stop="..."
    # y suma 'off' horas, cambiando +ZZZZ por +0100.
    awk -v off="$offset" -v ch="$ch_name_clean" '
    /<programme/ {
        # Buscamos si la línea actual contiene el nombre del canal
        if ($0 ~ ch) {
            # --- Modificar start ---
            if (match($0, /start="([0-9]{14}) [+-][0-9]+"/, arr)) {
                # Extraemos hora y minutos de la posición 9-14 (14 chars total: AAAAMMDDHHMMSS)
                # substr(arr[1], 9, 2) es la hora (ej. 06)
                # substr(arr[1], 11, 2) son los minutos (ej. 00)
                hora_actual = substr(arr[1], 9, 2) + 0
                min_actual = substr(arr[1], 11, 2) + 0
                
                # Sumamos el offset recibido desde el bucle bash
                hora_nueva = hora_actual + off
                
                # Ajuste simple para no saldarnos de las 23:59 (restamos 24 si pasamos)
                if (hora_nueva > 23) hora_nueva = hora_nueva - 24
                if (hora_nueva < 0) hora_nueva = 24 + hora_nueva
                
                # Formateamos la nueva hora con cero a la izquierda
                nueva_hora = sprintf("%02d", hora_nueva)
                
                # Reemplazamos el atributo start.
                # Sintaxis: start="AAAAMMDDHHMMSS +ZZZZ"
                # Sustituimos la hora y los minutos, y forzamos +0100 (Invierno España).
                # substr(arr[1], 1, 8) da la fecha AAAAMMDD.
                # Añadimos la nueva hora y los minutos originales.
                nuevo_start = sprintf("start=\"%s%02d%02d +0100\"", substr(arr[1], 1, 8), hora_nueva, min_actual)
                $0 = gensub(/start="[0-9]{14} [+-][0-9]+"/, nuevo_start, "g", $0)
            }
            
            # --- Modificar stop (mismo principio) ---
            if (match($0, /stop="([0-9]{14}) [+-][0-9]+"/, arrS)) {
                hora_s = substr(arrS[1], 9, 2) + 0
                min_s = substr(arrS[1], 11, 2) + 0
                hora_nueva_s = hora_s + off
                
                if (hora_nueva_s > 23) hora_nueva_s = hora_nueva_s - 24
                if (hora_nueva_s < 0) hora_nueva_s = 24 + hora_nueva_s
                
                nueva_hora_s = sprintf("%02d", hora_nueva_s)
                
                nuevo_stop = sprintf("stop=\"%s%02d%02d +0100\"", substr(arrS[1], 1, 8), hora_nueva_s, min_s)
                $0 = gensub(/stop="[0-9]{14} [+-][0-9]+"/, nuevo_stop, "g", $0)
            }
        }
    }
    { print }
    ' miEPG.xml > miEPG_temp.xml && mv miEPG_temp.xml miEPG.xml

done < canales.txt

echo "=== Ajustes de zona horaria finalizados ==="

# ==============================================================================

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

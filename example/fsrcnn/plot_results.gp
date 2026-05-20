# Gnuplot script to plot FSRCNN comparison results

# Output configuration for Throughput
set terminal pngcairo size 800,600 enhanced font 'Helvetica,11'
set output 'fsrcnn_throughput.png'

# Styling
set style fill solid 0.8 border -1
set boxwidth 0.5

# Grid settings
set grid ytics lc rgb "#dddddd" lw 1
set grid xtics lc rgb "#dddddd" lw 1

# Axes settings for Throughput
set ylabel "Throughput (FPS)" font 'Helvetica-Bold,12'
set xlabel "Skenario Percobaan" font 'Helvetica-Bold,12'
set title "FSRCNN Throughput Comparison (FPS)\n(Lebih tinggi lebih baik)" font 'Helvetica-Bold,14'
set yrange [0:80]
set xtics font 'Helvetica,10'
set ytics font 'Helvetica,10'

# Hide legend
unset key

# Plotting Throughput (column 3)
plot 'benchmark_data.dat' using 0:3:xtic(1) with boxes lc rgb "#1f77b4", \
     'benchmark_data.dat' using 0:3:3 with labels center offset 0,1 font 'Helvetica-Bold,10' textcolor rgb "#333333"

# Output configuration for Execution Time
set output 'fsrcnn_time.png'
set ylabel "Execution Time (ms)" font 'Helvetica-Bold,12'
set title "FSRCNN Average Execution Time Comparison\n(Lebih rendah lebih baik)" font 'Helvetica-Bold,14'
set yrange [0:3000]

# Plotting Execution Time (column 2)
plot 'benchmark_data.dat' using 0:2:xtic(1) with boxes lc rgb "#d62728", \
     'benchmark_data.dat' using 0:2:2 with labels center offset 0,1 font 'Helvetica-Bold,10' textcolor rgb "#333333"

# Output configuration for Energy
set output 'fsrcnn_energy.png'
set ylabel "Energy (J)" font 'Helvetica-Bold,12'
set title "FSRCNN Energy Consumption Comparison\n(Lebih rendah lebih baik)" font 'Helvetica-Bold,14'
set yrange [0:*]

# Plotting Energy (column 4)
stats 'benchmark_data.dat' using 4 nooutput
if (STATS_records > 0) {
    plot 'benchmark_data.dat' using 0:4:xtic(1) with boxes lc rgb "#2ca02c", \
         'benchmark_data.dat' using 0:4:4 with labels center offset 0,1 font 'Helvetica-Bold,10' textcolor rgb "#333333"
} else {
    unset xtics
    unset ytics
    unset grid
    unset border
    set label 1 "Data energi tidak tersedia\njalankan dengan sudo/PowerTop" at screen 0.5,0.5 center font 'Helvetica-Bold,13' textcolor rgb "#555555"
    plot 1/0 notitle
}

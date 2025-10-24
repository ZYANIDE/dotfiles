function get_focused_column() (
    niri msg focused-window | sed -n 's/.*column \([0-9]\+\).*/\1/p'
)

function get_focused_workspace() (
    niri msg focused-window | sed -n 's/.*Workspace ID: \([0-9]\+\).*/\1/p'
)

function get_max_column() (
    niri msg windows | awk 'BEGIN {RS="";max_col=0} /Workspace ID: '"$(get_focused_workspace)"'/ { if(match($0, /column ([0-9]+)/, m)) { if(m[1] > max_col) max_col=m[1] }} END {print max_col}'
)

function count_tiles_in_focused_column() (
    niri msg windows | awk -v ws="$(get_focused_workspace)" -v col="$(get_focused_column)" 'BEGIN {RS="";max_tile=0}
        $0 ~ "Workspace ID: " ws {
	    if(match($0, "column " col ", tile ([0-9]+)", m)) {
                if(m[1] > max_tile) max_tile = m[1]
            }
        }
        END {print max_tile}'
)

if [ "$(count_tiles_in_focused_column)" -eq 1 ] && [ "$(get_focused_column)" -eq "$(get_max_column)" ]; then
    niri msg action move-column-to-monitor-right
    # BUG: required to make 'move-column-to-monitor-right' function properly
    if [ "$(get_focused_column)" -ne 1 ]; then niri msg action swap-window-left; fi
else
    niri msg action consume-or-expel-window-right
fi

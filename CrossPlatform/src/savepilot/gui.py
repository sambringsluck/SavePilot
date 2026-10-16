from __future__ import annotations

import argparse
import queue
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from .core import confirm_move, discover_profiles, load_profiles, recommend


class SavePilotGUI:
    def __init__(self, watched: list[Path], roots: list[Path]):
        self.watched = watched
        self.roots = roots
        self.profiles = load_profiles() or discover_profiles(roots)
        self.events: queue.Queue = queue.Queue()
        self.items = []
        self.known = self._snapshot()
        self.root = tk.Tk()
        self.root.title("SavePilot")
        self.root.geometry("920x600")
        self._build()
        threading.Thread(target=self._monitor, daemon=True).start()
        self.root.after(300, self._drain)

    def _build(self):
        outer = ttk.Panedwindow(self.root, orient=tk.HORIZONTAL)
        outer.pack(fill=tk.BOTH, expand=True, padx=12, pady=12)
        left, right = ttk.Frame(outer), ttk.Frame(outer)
        outer.add(left, weight=1); outer.add(right, weight=3)
        ttk.Label(left, text="等待确认", font=("", 16, "bold")).pack(anchor="w", pady=(0, 8))
        self.listbox = tk.Listbox(left, exportselection=False)
        self.listbox.pack(fill=tk.BOTH, expand=True)
        self.listbox.bind("<<ListboxSelect>>", lambda _: self._select())
        ttk.Label(right, text="推荐存放位置").grid(row=0, column=0, sticky="w")
        self.path_var = tk.StringVar()
        ttk.Entry(right, textvariable=self.path_var).grid(row=1, column=0, sticky="ew", pady=(4, 14))
        self.name_label = ttk.Label(right, text="推荐文件名")
        self.name_var = tk.StringVar()
        self.name_entry = ttk.Entry(right, textvariable=self.name_var)
        self.reason = tk.Text(right, height=9, wrap="word", state="disabled")
        self.reason.grid(row=4, column=0, sticky="nsew", pady=14)
        buttons = ttk.Frame(right); buttons.grid(row=5, column=0, sticky="e")
        ttk.Button(buttons, text="跳过", command=self._dismiss).pack(side=tk.LEFT, padx=4)
        ttk.Button(buttons, text="确认存放", command=self._confirm).pack(side=tk.LEFT, padx=4)
        right.columnconfigure(0, weight=1); right.rowconfigure(4, weight=1)

    def _snapshot(self):
        result = {}
        for folder in self.watched:
            try:
                for item in folder.iterdir():
                    if item.is_file() and not item.name.startswith("."):
                        stat = item.stat(); result[item] = (stat.st_mtime_ns, stat.st_size)
            except OSError: pass
        return result

    def _monitor(self):
        while True:
            time.sleep(1.5)
            current = self._snapshot()
            changed = [path for path, stamp in current.items() if self.known.get(path) != stamp]
            time.sleep(0.8)
            stable = self._snapshot()
            for path in changed:
                if stable.get(path) == current.get(path): self.events.put(recommend(path, self.roots, self.profiles))
            self.known = stable

    def _drain(self):
        while not self.events.empty():
            item = self.events.get(); self.items.append(item); self.listbox.insert(tk.END, Path(item.source).name)
            if len(self.items) == 1: self.listbox.selection_set(0); self._select()
        self.root.after(300, self._drain)

    def _select(self):
        selected = self.listbox.curselection()
        if not selected: return
        item = self.items[selected[0]]
        self.path_var.set(item.destination); self.name_var.set(item.proposed_file_name)
        if item.changes_name:
            self.name_label.grid(row=2, column=0, sticky="w")
            self.name_entry.grid(row=3, column=0, sticky="ew", pady=(4, 0))
        else:
            self.name_label.grid_remove(); self.name_entry.grid_remove()
        self.reason.configure(state="normal"); self.reason.delete("1.0", tk.END)
        self.reason.insert("1.0", f"{item.reason}\n\n置信度：{item.confidence:.0%}")
        self.reason.configure(state="disabled")

    def _dismiss(self):
        selected = self.listbox.curselection()
        if selected: self._remove(selected[0])

    def _confirm(self):
        selected = self.listbox.curselection()
        if not selected: return
        index = selected[0]; item = self.items[index]
        try:
            target = confirm_move(item, Path(self.path_var.get()), self.name_var.get())
            messagebox.showinfo("SavePilot", f"已存放到：\n{target}")
            self._remove(index)
        except OSError as error:
            messagebox.showerror("SavePilot", str(error))

    def _remove(self, index):
        self.listbox.delete(index); self.items.pop(index)
        if self.items: self.listbox.selection_set(min(index, len(self.items) - 1)); self._select()

    def run(self): self.root.mainloop()


def main() -> int:
    parser = argparse.ArgumentParser(description="SavePilot cross-platform review window")
    parser.add_argument("--watch", action="append")
    parser.add_argument("--root", action="append")
    args = parser.parse_args()
    tk_root = tk.Tk(); tk_root.withdraw()
    watched = [Path(value).expanduser().resolve() for value in (args.watch or [])]
    roots = [Path(value).expanduser().resolve() for value in (args.root or [])]
    if not watched:
        selected = filedialog.askdirectory(title="选择监听目录"); watched = [Path(selected)] if selected else []
    if not roots:
        selected = filedialog.askdirectory(title="选择归档根目录"); roots = [Path(selected)] if selected else []
    tk_root.destroy()
    if not watched or not roots: return 1
    SavePilotGUI(watched, roots).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python
import os
import logging
import pathlib
import tarfile
import requests
import git


def get_git_repo(path):
    try:
        return git.Repo(path)
    except (git.exc.InvalidGitRepositoryError, git.exc.NoSuchPathError):
        return None

def find_comfyui_repo(base_path):
    def is_comfyui_dir(path):
        dir_path = os.path.join(base_path, path)
        return dir_path if all((
            path.casefold() == 'comfyui'.casefold(),
            os.path.isdir(dir_path)
        )) else None

    for dir_name in filter(None, map(is_comfyui_dir, os.listdir(base_path))):
        if repo := get_git_repo(os.path.join(base_path, dir_name)):
            return repo

    return None

try:
    print(f'Retrieving ComfyUI release info...')
    comfy_latest = requests.get('https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest')
    comfy_latest.raise_for_status()

    comfy_json = comfy_latest.json()
    if comfy_tag := comfy_json.get('tag_name', None):
        if repo := find_comfyui_repo(os.getcwd()):
            print(f'Updating ComfyUI repo from remote...')
            repo.git.fetch('--tags')

            if comfy_tag in repo.tags:
                repo.git.checkout(comfy_tag)
                print(f'ComfyUI updated to version {comfy_tag}.')
                exit(0)

            raise ValueError(f'Unable to find tag in repo: "{comfy_tag}"')

        raise RuntimeError(f'Unable to find ComfyUI repo in "{os.getcwd()}".')

    raise KeyError('No tag name found for latest release.')

except Exception as err:
    print(f'Failed to download ComfyUI update: {err}')

exit(1)
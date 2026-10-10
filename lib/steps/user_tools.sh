#!/bin/bash

step_user_tools() {
    stage "uv 工具 / Hugging Face CLI"
    install_huggingface_tool
}

step_hf_auth() {
    stage "Hugging Face 登录"
    offer_huggingface_login
}

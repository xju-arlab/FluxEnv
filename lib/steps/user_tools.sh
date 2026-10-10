#!/bin/bash

step_user_tools() {
    stage "uv 工具 / Hugging Face CLI / Node.js"
    install_huggingface_tool
    install_javascript_tools
}

step_hf_auth() {
    stage "Hugging Face 登录"
    offer_huggingface_login
}
